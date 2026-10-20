import Foundation
import Combine
import BooksCore
import BooksPlatform

/// One imported EPUB edition stored on this device.
struct Edition: Identifiable, Equatable {
    let publication: EPUBPublication
    let directory: URL
    var id: String { bookID }
    /// The journal book for this edition; identical on Mac and iOS for the same file.
    var bookID: String { "epub:" + publication.id }
    var coverURL: URL? {
        publication.coverPath.map { directory.appendingPathComponent("resources").appendingPathComponent($0) }
    }
}

struct JournalNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// The iOS app's model: the Mac's `ReadingStore`, `TrackingEngine` and EPUB importer
/// behind one main-actor object. Reading time is credited only while the app is
/// active and the built-in reader is open and ready (see docs/IOS_APP.md).
@MainActor
final class Journal: ObservableObject {
    typealias Clock = () -> (date: Date, uptime: TimeInterval)

    @Published private(set) var history: HistoryPresentation
    @Published private(set) var sessions: [ReadingSessionGroup] = []
    /// Imported editions keyed by journal book ID (`epub:<sha256>`).
    @Published private(set) var editions: [String: Edition] = [:]
    @Published private(set) var tracker = TrackerSnapshot()
    @Published private(set) var importStatus: String?
    @Published private(set) var trackingEnabled: Bool
    @Published private(set) var timezoneID: String
    /// The book open in the reader, if any.
    @Published private(set) var readingBookID: String?
    @Published var notice: JournalNotice?

    let paths: JournalPaths
    private let store: ReadingStore
    private var engine: TrackingEngine
    private let importer: EPUBPublicationImporter
    private let defaults: UserDefaults
    private let clock: Clock
    private let usesTimer: Bool
    private var booksByID: [String: BookRecord] = [:]
    private var resolver = BookMergeResolver(merges: [])
    private var trackingStopped = false

    private var sceneActive = true
    private var readerReady = false
    private var latestProgress: ProgressObservation?
    private var timer: Timer?
    private var lastHistoryRefresh = Date.distantPast

    private var pendingImports: [URL] = []
    private var importing = false

    private let refreshQueue = DispatchQueue(label: "Stillleaf.history", qos: .userInitiated)
    private var refreshGeneration = 0
    private var refreshInFlight = false
    private var refreshPending = false

    static let defaultGoal: Double = 20

    init(paths: JournalPaths, defaults: UserDefaults = .standard, usesTimer: Bool = true,
         clock: @escaping Clock = { (Date(), ProcessInfo.processInfo.systemUptime) }) throws {
        let paths = try paths.prepared()
        self.paths = paths
        self.defaults = defaults
        self.clock = clock
        self.usesTimer = usesTimer
        store = try ReadingStore(url: paths.history)
        let zone = defaults.string(forKey: "timezoneID").flatMap { TimeZone(identifier: $0) }?.identifier ?? TimeZone.current.identifier
        timezoneID = zone
        trackingEnabled = defaults.object(forKey: "trackingEnabled") as? Bool ?? true
        engine = try TrackingEngine(store: store, timezoneID: zone)
        importer = EPUBPublicationImporter(directory: paths.publications)
        history = HistoryPresentation(archive: HistoryArchive(), effectiveIntervals: [], timezoneID: zone, goalMinutes: Self.defaultGoal)
        tracker = engine.snapshot
        try ensureDailyGoal()
        refresh()
    }

    /// The production journal in Application Support.
    static func live() throws -> Journal { try Journal(paths: .applicationSupport()) }

    // MARK: - Derived state

    var books: [BookRecord] { history.librarySummary.books }
    func book(_ id: String) -> BookRecord? { booksByID[id] }
    func canonicalID(_ id: String) -> String { resolver.resolvedID(for: id) }
    func edition(forBook id: String) -> Edition? { editions[id] }
    var todayKey: String { ReadingStatistics.dayKey(clock().date, timezoneID: timezoneID) }

    /// The daily goal in effect today.
    var dailyGoal: GoalChange? {
        let today = todayKey
        return history.goalHistory.enumerated().filter { $0.element.effectiveDay <= today }.max { lhs, rhs in
            lhs.element.effectiveDay == rhs.element.effectiveDay ? lhs.offset < rhs.offset : lhs.element.effectiveDay < rhs.element.effectiveDay
        }?.element
    }

    var todayGoal: DailyGoalProgress {
        history.goalProgressByDay[todayKey] ?? ReadingGoals.daily(day: todayKey, pages: history.todayPages,
            creditedSeconds: history.today.creditedSeconds, goals: history.goalHistory)
    }

    func secondsRead(bookID: String) -> Double {
        let id = canonicalID(bookID)
        return history.intervals.filter { $0.disposition == .credited && canonicalID($0.bookID) == id }.reduce(0) { $0 + $1.duration }
    }

    func pagesRead(bookID: String) -> Int { history.pageEvidence.pages(bookID: canonicalID(bookID)) }
    func pages(sessionID: String) -> Int { history.pageEvidence.pages(sessionID: sessionID) }
    func position(bookID: String) -> ProgressObservation? { history.libraryPositions[canonicalID(bookID)] }
    func finished(bookID: String) -> FinishedBookEntry? { history.finishedBooks.first { $0.id == canonicalID(bookID) } }
    func rating(bookID: String) -> Double? { history.bookRatings[canonicalID(bookID)] }
    func review(bookID: String) -> String? { history.bookReviewCache[canonicalID(bookID)] }

    /// Reading sessions that started on a calendar day key, newest first.
    func sessions(onDay day: String) -> [ReadingSessionGroup] {
        sessions.filter { ReadingStatistics.dayKey($0.start, timezoneID: timezoneID) == day }.sorted { $0.start > $1.start }
    }

    /// The most recently read book that can be opened here.
    var continueReading: BookRecord? {
        history.intervals.lazy.compactMap { [self] interval -> BookRecord? in
            guard self.editions[interval.bookID] != nil else { return nil }
            return self.booksByID[interval.bookID]
        }.first ?? editions.values.compactMap { booksByID[$0.bookID] }.sorted { $0.observedAt > $1.observedAt }.first
    }

    // MARK: - Reader and tracking

    /// Called when the reader is presented. Time starts only after `readerBecameReady`.
    func readerOpened(bookID: String) {
        readingBookID = bookID
        readerReady = false
        latestProgress = nil
        startTimer()
        tick()
    }

    func readerBecameReady(bookID: String) {
        guard readingBookID == bookID else { return }
        readerReady = true
        tick()
    }

    func readerMoved(_ observation: ProgressObservation) {
        guard readingBookID == observation.bookID else { return }
        latestProgress = observation
    }

    /// Forward sequential page coverage, recorded only inside a session already being credited.
    func readerTraversed(bookID: String, evidence: PageTurnEvidence) {
        guard readingBookID == bookID, readerReady, sceneActive, trackingEnabled, !trackingStopped else { return }
        let previousSession = tracker.book?.id == bookID ? tracker.sessionID : nil
        tick()
        guard let sessionID = previousSession, tracker.sessionID == sessionID, tracker.phase != .paused,
              tracker.book?.trackingExcluded == false else { return }
        do {
            let now = clock()
            try engine.checkpoint(date: now.date, uptime: now.uptime)
            tracker = engine.snapshot
            guard tracker.phase != .paused else { return }
            try store.appendEvent(AuditEvent(date: now.date, kind: "pageTurn", bookID: bookID, sessionID: sessionID,
                detail: "Native sequential navigation over the supplied chapter text range; not a comprehension claim.", pageTurn: evidence))
            requestRefresh()
        } catch { trackingFailed(error) }
    }

    func readerClosed(bookID: String) {
        guard readingBookID == bookID else { return }
        recordFinalPosition()
        readingBookID = nil
        readerReady = false
        latestProgress = nil
        tick()
        stopTimer()
        refresh()
    }

    /// Scene activity: anything but `.active` (background, app switcher, Control Centre,
    /// a call, a locked screen) pauses immediately and saves the current position.
    func sceneActivityChanged(active: Bool) {
        guard sceneActive != active else { return }
        sceneActive = active
        if !active { recordFinalPosition() }
        tick()
        if active { refresh() }
    }

    /// Why time is not being credited right now, or nil while reading counts.
    var pauseReason: PauseReason? {
        if !trackingEnabled { return .disabled }
        if !sceneActive { return .background }
        guard let id = readingBookID, readerReady, booksByID[id] != nil else { return .noReadingWindow }
        return nil
    }

    /// One tracking sample. The timer calls this every second while a reader is open.
    func tick() {
        guard !trackingStopped else { return }
        let now = clock()
        let previous = tracker
        do {
            if pauseReason == nil, let id = readingBookID, let book = booksByID[id] {
                try engine.process(TrackingInput(date: now.date, uptime: now.uptime, book: book, mode: .automatic,
                                                 pauseReason: book.trackingExcluded ? .excludedBook : nil, progress: latestProgress))
            } else {
                try engine.process(TrackingInput(date: now.date, uptime: now.uptime, mode: .automatic,
                                                 pauseReason: pauseReason ?? .noReadingWindow))
            }
            tracker = engine.snapshot
            if previous.phase != tracker.phase || previous.book?.id != tracker.book?.id
                || now.date.timeIntervalSince(lastHistoryRefresh) >= 15 { requestRefresh() }
        } catch { trackingFailed(error) }
    }

    private func recordFinalPosition() {
        guard trackingEnabled, !trackingStopped, let progress = latestProgress else { return }
        do { try engine.recordPosition(progress) } catch { trackingFailed(error) }
    }

    private func startTimer() {
        guard usesTimer, timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func trackingFailed(_ error: Error) {
        trackingStopped = true
        stopTimer()
        notice = JournalNotice(title: "Tracking stopped",
            message: "Reading time is no longer being recorded because it could not be saved. Your earlier history is intact. \(error.localizedDescription)")
    }

    // MARK: - Import

    /// Imports EPUBs one at a time. Security-scoped URLs from the document picker are
    /// opened for the copy only; files the system placed in `Documents/Inbox` are removed.
    /// Returns when the queue is empty, or at once if an import already running takes these too.
    func importEPUBs(_ urls: [URL]) async {
        pendingImports.append(contentsOf: urls)
        guard !importing else { return }
        importing = true
        await runImports()
    }

    private func runImports() async {
        var imported: [String] = [], duplicates = 0, failures: [String] = []
        var done = 0
        while !pendingImports.isEmpty {
            let url = pendingImports.removeFirst()
            done += 1
            importStatus = "Importing \(done) of \(done + pendingImports.count)…"
            let importer = self.importer
            let result = await Task.detached(priority: .userInitiated) { () -> Result<EPUBPublicationImportResult, Error> in
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
                }
                return Result { try importer.importPublication(from: url) }
            }.value
            switch result {
            case .success(let edition):
                do {
                    try register(edition)
                    if edition.alreadyImported { duplicates += 1 } else { imported.append(edition.publication.title) }
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            case .failure(let error):
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        importing = false
        importStatus = nil
        refresh()
        var lines: [String] = []
        if imported.count == 1 { lines.append("Added “\(imported[0])”.") }
        else if imported.count > 1 { lines.append("Added \(imported.count) books.") }
        if duplicates > 0 { lines.append(duplicates == 1 ? "1 book was already in your library." : "\(duplicates) books were already in your library.") }
        if !failures.isEmpty { lines.append((failures.count == 1 ? "This file could not be imported:\n" : "These files could not be imported:\n") + failures.joined(separator: "\n")) }
        if !failures.isEmpty || imported.isEmpty {
            notice = JournalNotice(title: failures.isEmpty ? "Import" : "Import finished with problems", message: lines.joined(separator: "\n\n"))
        }
    }

    /// Adds a journal book for a new edition. An existing record keeps its title, exclusions and reviews.
    private func register(_ result: EPUBPublicationImportResult) throws {
        let edition = Edition(publication: result.publication, directory: result.directory)
        if booksByID[edition.bookID] == nil {
            let authors = result.publication.authors
            let book = BookRecord(id: edition.bookID, title: result.publication.title,
                                  author: authors.isEmpty ? nil : authors.joined(separator: ", "), source: "stillleaf-epub")
            try store.saveBook(book)
            booksByID[book.id] = book
        }
        editions[edition.bookID] = edition
    }

    /// Loads editions already on this device and restores any missing journal book.
    func loadLibrary() async {
        let importer = self.importer
        let recovered = await Task.detached(priority: .utility) { Result { try importer.recoverLibrary() } }.value
        switch recovered {
        case .success(let library):
            for publication in library.publications {
                do { try register(publication) } catch { notice = JournalNotice(title: "Library", message: error.localizedDescription) }
            }
            refresh()
            if library.failedCount > 0 {
                notice = JournalNotice(title: "Some books could not be loaded",
                    message: (["\(library.failedCount) imported book(s) are damaged. Import them again."] + library.warnings).joined(separator: "\n"))
            }
        case .failure(let error):
            notice = JournalNotice(title: "Library", message: "Imported books could not be loaded. \(error.localizedDescription)")
        }
    }

    // MARK: - Journal edits

    @discardableResult
    func markFinished(_ bookID: String, at date: Date? = nil) -> Bool {
        let id = canonicalID(bookID)
        guard booksByID[id] != nil else { return fail("This book is no longer in your library.") }
        guard finished(bookID: id) == nil else { return true }
        let when = date ?? clock().date
        return perform { try store.appendEvent(AuditEvent(date: clock().date, kind: "bookCompleted", bookID: id,
            detail: "Marked finished by the reader.", completion: BookCompletionEvidence(finishedAt: when, source: "You", imported: false))) }
    }

    /// Corrects saved completion dates without inferring any reading activity.
    @discardableResult
    func saveReadingDates(_ dates: ReadingCompletionDates, for bookID: String) -> Bool {
        let id = canonicalID(bookID)
        guard let existing = finished(bookID: id) else { return fail("This book is no longer marked as read.") }
        if existing.startedAt == dates.startedAt, existing.finishedAt == dates.finishedAt { return true }
        let now = clock().date
        if let message = dates.validationMessage(now: now) { return fail(message) }
        return perform { try store.appendEvent(AuditEvent(date: now, kind: "bookCompleted", bookID: id,
            detail: "Reading dates edited by the reader; no reading activity inferred.",
            completion: BookCompletionEvidence(startedAt: dates.startedAt, finishedAt: dates.finishedAt, source: "You", imported: false))) }
    }

    @discardableResult
    func saveRating(_ rating: Double?, for bookID: String) -> Bool {
        let id = canonicalID(bookID)
        guard booksByID[id] != nil, rating.map({ $0.isFinite && $0 >= 0 && $0 <= 5 && ($0 * 4).rounded() == $0 * 4 }) ?? true else {
            return fail("Choose a rating from 0 to 5 in quarter-star steps.")
        }
        return perform { try store.appendEvent(AuditEvent(date: clock().date, kind: "bookRated", bookID: id,
            detail: rating == nil ? "Rating cleared by the reader." : "Rating chosen by the reader.", rating: BookRatingEvidence(value: rating))) }
    }

    @discardableResult
    func saveReview(_ text: String?, for bookID: String) -> Bool {
        let id = canonicalID(bookID)
        guard booksByID[id] != nil, (text?.count ?? 0) <= 50_000 else { return fail("Keep your review within 50,000 characters.") }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let review = trimmed?.isEmpty == false ? trimmed : nil
        guard review != self.review(bookID: id) else { return true }
        return perform { try store.appendEvent(AuditEvent(date: clock().date, kind: "bookReviewed", bookID: id,
            detail: review == nil ? "Written review cleared by the reader." : "Local written review saved by the reader.",
            review: BookReviewEvidence(text: review))) }
    }

    @discardableResult
    func setTrackingExcluded(_ excluded: Bool, for bookID: String) -> Bool {
        guard var book = booksByID[bookID], book.trackingExcluded != excluded else { return true }
        return perform {
            if tracker.book?.id == bookID { try stopTracking() }
            book.observedAt = clock().date
            book.trackingExcluded = excluded
            try store.saveBook(book)
        }
    }

    /// Validates and saves a past session the reader logs by hand (a paper book, another device).
    @discardableResult
    func logReading(book: BookRecord, end: Date, minutes: Int, pages: Int?) -> Bool {
        let entry = ManualReadingEntry(bookID: book.id, end: end, seconds: TimeInterval(max(0, minutes) * 60),
                                       pages: pages.map { .count($0) }, totalPages: nil, timezoneID: timezoneID)
        if let issue = entry.issue(existing: history.intervals, now: clock().date) { return fail(Self.describe(issue)) }
        return perform { try store.saveManualEntry(book: book, records: entry.records(now: clock().date)) }
    }

    static func describe(_ issue: ManualEntryIssue) -> String {
        switch issue {
        case .nothingToLog: return "Enter minutes, pages, or both."
        case .pagesNotPositive: return "Pages must be more than zero."
        case .pagesTooMany(let limit): return "Log at most \(limit.formatted()) pages at once."
        case .pageBeyondTotal(let total): return "This book has \(total) pages."
        case .durationTooLong: return "Log at most 24 hours at once."
        case .inFuture: return "Choose a time that has already passed."
        case .overlaps(let start, let end):
            return "This overlaps reading already recorded from \(start.formatted(date: .abbreviated, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))."
        }
    }

    @discardableResult
    func deleteSession(_ sessionID: String) -> Bool {
        perform(rebuildingTracker: true) {
            try stopTracking()
            try store.deleteSession(sessionID)
        }
    }

    /// Deletes the book's journal records and, if present, its EPUB on this device.
    @discardableResult
    func deleteBook(_ bookID: String) -> Bool {
        guard readingBookID != bookID else { return fail("Close the book before deleting it.") }
        return perform(rebuildingTracker: true) {
            try stopTracking()
            try store.deleteBook(bookID)
            if let edition = editions[bookID] { try removeFiles(of: edition) }
        }
    }

    /// Removes only the EPUB from this device. Its reading history stays in the journal.
    @discardableResult
    func removeDownload(_ bookID: String) -> Bool {
        guard readingBookID != bookID else { return fail("Close the book before removing it.") }
        guard let edition = editions[bookID] else { return true }
        return perform { try removeFiles(of: edition) }
    }

    private func removeFiles(of edition: Edition) throws {
        let removal = EPUBAssetRemoval(directory: paths.publications) { url in
            // iOS has no user-visible Trash: move the validated edition aside, then delete it.
            let aside = FileManager.default.temporaryDirectory.appendingPathComponent("removed-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.moveItem(at: url, to: aside)
            return aside
        }
        let result = try removal.remove(publicationID: edition.publication.id)
        try? FileManager.default.removeItem(at: result.trashedDirectory)
        for name in [edition.publication.id + ".json", edition.publication.id + ".json.bak"] {
            try? FileManager.default.removeItem(at: paths.readerState.appendingPathComponent(name))
        }
        editions[edition.bookID] = nil
    }

    // MARK: - Settings

    func setTrackingEnabled(_ enabled: Bool) {
        guard trackingEnabled != enabled else { return }
        if !enabled { recordFinalPosition() }
        trackingEnabled = enabled
        defaults.set(enabled, forKey: "trackingEnabled")
        tick()
    }

    /// Saves daily and yearly goals together. A daily change takes effect today.
    @discardableResult
    func saveGoals(unit: DailyGoalUnit, pages: Int, minutes: Int, annualBooks: Int?) -> Bool {
        guard ReadingGoalLimits.dailyPages.contains(pages), ReadingGoalLimits.dailyMinutes.contains(minutes),
              annualBooks.map({ ReadingGoalLimits.annualBooks.contains($0) }) ?? true else {
            return fail("Choose a whole-page goal from 1–10,000, a time goal from 1–1,440 minutes, and a yearly goal from 1–10,000 books.")
        }
        let now = clock().date
        let current = dailyGoal
        let dailyChanged = current?.resolvedUnit != unit || current?.pages != Double(pages) || current?.minutes != Double(minutes)
        let daily = dailyChanged ? GoalChange(effectiveDay: todayKey, minutes: Double(minutes), pages: Double(pages),
                                              createdAt: now, primaryUnit: unit) : nil
        let year = goalYear(now)
        let annual = history.annualBookGoal != annualBooks ? AuditEvent(date: now, kind: "annualGoalChanged",
            detail: "Yearly books goal chosen by the reader.", annualGoal: AnnualGoalEvidence(year: year, books: annualBooks)) : nil
        return perform { try store.setReadingGoals(daily: daily, annual: annual) }
    }

    /// Regroups history by a different calendar time zone, as the Mac does.
    @discardableResult
    func setTimezone(_ identifier: String) -> Bool {
        guard identifier != timezoneID else { return true }
        guard TimeZone(identifier: identifier) != nil else { return fail("Choose a valid time zone.") }
        return perform {
            try stopTracking()
            try store.setReadingGoals(daily: nil, annual: nil,
                calendarChange: AuditEvent(date: clock().date, kind: "calendarTimezoneChanged", detail: identifier))
            engine.timezoneID = identifier
            timezoneID = identifier
            defaults.set(identifier, forKey: "timezoneID")
        }
    }

    private func goalYear(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        return calendar.component(.year, from: date)
    }

    private func ensureDailyGoal() throws {
        guard try store.archive().goals.isEmpty else { return }
        try store.setGoal(GoalChange(effectiveDay: todayKey, minutes: Self.defaultGoal, pages: Self.defaultGoal,
                                     createdAt: clock().date, primaryUnit: .pages))
    }

    // MARK: - Data

    /// The complete versioned JSON archive the Mac imports.
    func exportJSON() throws -> URL {
        try checkpoint()
        let url = try exportLocation("Stillleaf-history.json")
        try store.exportJSON(to: url)
        return url
    }

    /// The Mac's CSV table set, in one folder.
    func exportCSV() throws -> URL {
        try checkpoint()
        let url = try exportLocation("Stillleaf-export-\(Int(clock().date.timeIntervalSince1970))")
        try store.exportCSV(to: url)
        return url
    }

    /// A SQLite backup in the Mac's format.
    func backup() throws -> URL {
        try checkpoint()
        let url = try exportLocation("Stillleaf-backup.sqlite")
        try store.backup(to: url)
        return url
    }

    /// Merges a JSON archive (from this app or the Mac) into the journal; duplicates are skipped.
    @discardableResult
    func importJSON(from url: URL) -> Bool {
        withLocalCopy(of: url) { copy in
            perform(rebuildingTracker: true) {
                try stopTracking()
                try store.importJSON(from: copy)
            }
        }
    }

    /// Replaces the journal with a validated SQLite backup.
    @discardableResult
    func restore(from url: URL) -> Bool {
        withLocalCopy(of: url) { copy in
            perform(rebuildingTracker: true) {
                try stopTracking()
                try store.restore(from: copy)
                try ensureDailyGoal()
            }
        }
    }

    /// Deletes all journal records, imported books and reader state on this device.
    @discardableResult
    func deleteAllData() -> Bool {
        guard readingBookID == nil else { return fail("Close the book before deleting all data.") }
        return perform(rebuildingTracker: true) {
            try stopTracking()
            try store.deleteAll()
            for directory in [paths.publications, paths.readerState, paths.exports] where FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try paths.prepare()
            editions = [:]
            try ensureDailyGoal()
        }
    }

    /// Removes export files once the system exporter has copied them.
    func discardExports() {
        try? FileManager.default.removeItem(at: paths.exports)
    }

    private func exportLocation(_ name: String) throws -> URL {
        let folder = paths.exports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    private func checkpoint() throws {
        guard !trackingStopped else { return }
        let now = clock()
        try engine.checkpoint(date: now.date, uptime: now.uptime)
    }

    /// Files from the document picker are security scoped and may be in iCloud; work on a private copy.
    private func withLocalCopy(of url: URL, _ body: (URL) -> Bool) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            return body(copy)
        } catch { return fail(error.localizedDescription) }
    }

    // MARK: - Mutation plumbing

    private func stopTracking() throws {
        let now = clock()
        try engine.stop(date: now.date, uptime: now.uptime)
        tracker = engine.snapshot
    }

    @discardableResult
    private func perform(rebuildingTracker: Bool = false, _ body: () throws -> Void) -> Bool {
        var succeeded = true
        do { try body() } catch {
            succeeded = false
            notice = JournalNotice(title: "Not saved", message: error.localizedDescription)
        }
        if rebuildingTracker {
            do {
                engine = try TrackingEngine(store: store, timezoneID: timezoneID)
                tracker = engine.snapshot
                trackingStopped = false
            } catch { trackingFailed(error) }
        }
        refresh()
        return succeeded
    }

    @discardableResult
    private func fail(_ message: String) -> Bool {
        notice = JournalNotice(title: "Not saved", message: message)
        return false
    }

    // MARK: - History

    /// Recomputes history now. Used after explicit edits, which must read back immediately.
    func refresh() {
        refreshGeneration += 1
        refreshPending = false
        do {
            apply(HistoryPresentation(archive: try store.archive(), effectiveIntervals: try store.effectiveIntervals(),
                                      timezoneID: timezoneID, goalMinutes: dailyGoal?.minutes ?? Self.defaultGoal, now: clock().date))
        } catch { notice = JournalNotice(title: "History unavailable", message: error.localizedDescription) }
    }

    /// Coalesced background recomputation for tracking updates.
    func requestRefresh() {
        if refreshInFlight { refreshPending = true; return }
        refreshInFlight = true
        refreshPending = false
        let generation = refreshGeneration, url = paths.history, zone = timezoneID
        let goal = dailyGoal?.minutes ?? Self.defaultGoal, now = clock().date
        refreshQueue.async { [weak self] in
            let result = Result { () -> HistoryPresentation in
                let source = try ReadingStore.readSnapshot(at: url)
                return HistoryPresentation(archive: source.archive, effectiveIntervals: source.intervals,
                                           timezoneID: zone, goalMinutes: goal, now: now)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshInFlight = false
                if generation == self.refreshGeneration, zone == self.timezoneID, case .success(let presentation) = result {
                    self.apply(presentation)
                }
                if self.refreshPending { self.requestRefresh() }
            }
        }
    }

    private func apply(_ presentation: HistoryPresentation) {
        history = presentation
        booksByID = Dictionary(presentation.books.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        resolver = BookMergeResolver(merges: presentation.merges)
        sessions = ReadingSessionGrouping.groups(intervals: presentation.intervals, merges: presentation.merges,
                                                 breakBeforeIntervalIDs: presentation.sessionBreakIDs)
        lastHistoryRefresh = clock().date
    }
}

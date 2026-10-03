import AppKit
import SwiftUI
import BooksCore
import BooksPlatform
import UniformTypeIdentifiers
import CryptoKit

@MainActor
final class AppModel: ObservableObject {
    let audiobookPlayer = AudiobookPlayer()
    @Published private(set) var importingAudio = false
    let epubLibrary: EPUBLibraryController
    private var transferringReaderState = Set<String>()
    private let epubReaders: EPUBReaderWindows
    @Published private(set) var snapshot = TrackerSnapshot()
    @Published private(set) var books: [BookRecord] = []
    @Published private(set) var intervals: [ReadingInterval] = []
    @Published private(set) var events: [AuditEvent] = []
    @Published private(set) var progress: [ProgressObservation] = []
    @Published private(set) var merges: [BookMerge] = []
    @Published private(set) var preparingAppleBooksIDs = Set<String>()
    @Published private(set) var openingEPUBIDs = Set<String>()
    /// Apple Books asset IDs of store purchases, which only Apple Books can open.
    @Published private(set) var appleBooksStorePurchaseIDs = Set<String>()
    private var storePurchaseCheckInFlight = false
    private var lastStorePurchaseCheck = Date.distantPast
    private var pendingLinkOffers: [String] = []
    @Published private(set) var days: [DailyTotal] = []
    @Published private(set) var today = DailyTotal(day: "", creditedSeconds: 0, uncertainSeconds: 0, manualSeconds: 0, goalMinutes: 20)
    @Published private(set) var streak = StreakSummary(current: 0, longest: 0, todayPending: true, provisional: false)
    @Published private(set) var currentPagePosition: ReaderPagePosition?
    var currentPage: Int? { currentPagePosition?.page }
    var currentTotalPages: Int? { currentPagePosition?.totalPages }
    var currentPageText: String? {
        guard let page = currentPage else { return nil }
        return currentTotalPages.map { "Page \(page) of \($0)" } ?? "Page \(page)"
    }
    @Published private(set) var todayPages = 0
    @Published private(set) var sessionPages = 0
    @Published private(set) var pageStreak = StreakSummary(current: 0, longest: 0, todayPending: true, provisional: false)
    @Published private(set) var pageDays: [DailyPageTotal] = []
    @Published private(set) var finishedBooks: [FinishedBookEntry] = []
    @Published private(set) var historyAtlasSource: HistoryAtlasSource?
    @Published private(set) var pendingCompletion: FinishedBookEntry?
    @Published private(set) var pendingCompletionEventID: String?
    @Published private(set) var appleHistoryStatus = "Reading Apple Books history…"
    @Published private var publicCoverURLs: [String: String] = [:]
    @Published private(set) var health = "Starting the local tracker…"
    @Published private(set) var lastCapture: Date?
    @Published var errorMessage: String?
    @Published private(set) var trackingRecoveryRequired = false
    @Published private(set) var trackingRecoveryMessage: String?
    private var rebuildingTracker = false
    @Published private(set) var discordStatus = "Discord sharing is off."
    @Published private(set) var lastDiscordResult: String?
    @Published private(set) var accessibilityGranted = false
    private var readingTrackingSource: ReadingTrackingSource {
        ReadingTrackingSource.resolve(manualReading: manualActive,
            nativeReaderFocused: epubReaders.focusedPublicationID != nil,
            appleBooksForeground: SystemEligibility.booksForeground, accessibilityGranted: accessibilityGranted)
    }
    var appleBooksTrackingNeedsAccess: Bool {
        trackingEnabled && !audiobookPlayer.isPlaying && readingTrackingSource == .appleBooksNeedsAccess
    }
    var discordNeedsSetup: Bool { discordEnabled && discordApplicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @Published var trackingEnabled = true { willSet { if newValue != trackingEnabled { audiobookPlayer.pauseReportingErrors() } } didSet { if ready { defaults.set(trackingEnabled, forKey: "trackingEnabled"); if !trackingEnabled { pause(.disabled) } else { perform { try ensureCurrentPageGoal() } }; tick() } } }
    @Published var discordEnabled = false { didSet { if ready { defaults.set(discordEnabled, forKey: "discordEnabled"); publishPresence() } } }
    @Published var discordApplicationID = ""
    @Published var discordAssetKey = ""
    @Published var automaticPublicCovers = false
    @Published var syncAppleBooksHistoryEnabled = true
    @Published var goalMinutes: Double = 20
    @Published var pageGoal: Double = 20
    @Published var dailyGoalUnit: DailyGoalUnit = .pages
    @Published var annualBookGoal: Int?
    @Published private(set) var annualBooksFinished = 0
    @Published private(set) var dailyGoalStreak = StreakSummary(current: 0, longest: 0, todayPending: true, provisional: false)
    private var goalProgressByDay: [String: DailyGoalProgress] = [:]
    private var goalHistory: [GoalChange] = []
    private var bookReviewCache: [String: String] = [:]
    private var bookReviewDates: [String: Date] = [:]
    private var celebratedCompletionIDs: Set<String> = []
    var goalYear: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        return calendar.component(.year, from: Date())
    }
    func dailyGoal(on day: String) -> DailyGoalProgress {
        goalProgressByDay[day] ?? ReadingGoals.daily(day: day, pages: 0, creditedSeconds: 0, goals: goalHistory)
    }
    var todayGoal: DailyGoalProgress { dailyGoal(on: today.day) }
    @Published var timezoneID = TimeZone.current.identifier
    @Published var uncertaintyMinutes: Double = 20
    @Published var launchAtLogin = false

    private var pageDaysByKey: [String: DailyPageTotal] = [:]
    private var displayedIntervalsCache: [ReadingInterval]?
    private var sessionGroupsCache: [ReadingSessionGroup]?
    private struct CachedPace { let value: Double? }
    private var bookPaceCache: [String: CachedPace] = [:]
    private var sessionPaceCache: [String: CachedPace] = [:]
    private var bookPagesCache: [String: Int] = [:]
    private var sessionPagesCache: [String: Int] = [:]
    private var bookRatings: [String: Double] = [:]
    private var libraryPositions: [String: ProgressObservation] = [:]
    private(set) var librarySummary = LibraryHistorySummary()
    private var pageEvidenceCache: PageStatistics.Snapshot?
    private var pageEvidence: PageStatistics.Snapshot {
        if let cached = pageEvidenceCache { return cached }
        let prepared = PageStatistics.snapshot(events: events, effectiveIntervals: intervals, merges: merges)
        pageEvidenceCache = prepared
        return prepared
    }

    var displayIntervals: [ReadingInterval] {
        if let cached = displayedIntervalsCache { return cached }
        var result: [ReadingInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if var previous = result.last, previous.sessionID == interval.sessionID, previous.bookID == interval.bookID,
               previous.mode == interval.mode, previous.disposition == interval.disposition,
               abs(previous.end.timeIntervalSince(interval.start)) < 0.001 {
                result.removeLast()
                previous.id = previous.id.hasPrefix("group:") ? previous.id : "group:" + previous.id
                previous.end = interval.end; previous.duration += interval.duration; result.append(previous)
            } else { result.append(interval) }
        }
        let sorted = result.sorted { $0.start > $1.start }
        displayedIntervalsCache = sorted
        return sorted
    }
    var uncertainIntervals: [ReadingInterval] { displayIntervals.filter { $0.disposition == .uncertain } }
    private func originalIDs(for interval: ReadingInterval) -> [String] {
        guard interval.id.hasPrefix("group:") else { return [interval.id] }
        return intervals.filter { $0.sessionID == interval.sessionID && $0.bookID == interval.bookID && $0.disposition == interval.disposition && $0.start >= interval.start && $0.end <= interval.end }.map(\.id)
    }
    var manualActive: Bool { manualBook != nil }
    var dashboardAction: (() -> Void)?
    @Published var dashboardSectionRequest: DashboardSection?
    @Published var settingsCategoryRequest: SettingsCategory?
    private let defaults: UserDefaults
    private let support: URL
    private let store: ReadingStore
    private let historyReader: (URL) throws -> (archive: HistoryArchive, intervals: [ReadingInterval])
    private let makeTrackingEngine: (ReadingStore, String, TimeInterval) throws -> TrackingEngine
    private let accessibilityStatus: () -> Bool
    private var engine: TrackingEngine
    private let captures: BooksCapture
    private let covers: CoverCache
    private let discord = DiscordPresence()
    private var presencePolicy = ReadingPresencePolicy()
    private var readerWindow: BooksReaderWindow?
    private let readerCheckQueue = DispatchQueue(label: "Stillleaf.reader-liveness", qos: .utility)
    private var readerCheckInFlight = false
    private var readingActivityEvidence = ReadingActivityEvidence()
    private var pageTurnTracker = PageTurnTracker()
    private var readerPagination = ReaderPagination()
    private let publicCoverResolver = PublicCoverResolver()
    private var coverLookups: Set<String> = []
    private var coverLookupTasks: [String: Task<Void, Never>] = [:]
    private var coverLookupGeneration = 0
    private var coverLookupDates: [String: Date] = [:]
    private let historyQueue = DispatchQueue(label: "BooksPresence.finished-history", qos: .utility)
    private var historySyncInFlight = false
    private var historyGeneration = 0
    private var lastHistorySync = Date.distantPast
    private var suppressedHistoryIDs: Set<String> = []
    private var presenceState: ReadingPresenceState = .hidden
    private let captureQueue = DispatchQueue(label: "BooksPresence.capture", qos: .utility)
    private var captureInFlight = false
    private var captureStarted = Date.distantPast
    private var captureGeneration = 0
    private var timer: Timer?
    private var windowObserver: BooksWindowObserver?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var suspended: Set<String> = []
    private var manualBook: BookRecord?
    private var ready = false
    private var lastRefresh = Date.distantPast
    private var lastInputUptime: TimeInterval = 0
    private var lastHealthReason: PauseReason?
    private var latestProgress: ProgressObservation?
    private var hasPageNavigationSignal = false
    private var savedGoal: Double = 20
    private var savedPageGoal: Double = 20
    private var savedDailyGoalUnit: DailyGoalUnit = .pages
    private var sessionBreakIDs: Set<String> = []
    private var correctedIntervalIDs: Set<String> = []
    private var durableVisibleSessionIDs: Set<String>?
    private var visibleSessionGroupsCache: (activeID: String?, groups: [ReadingSessionGroup])?
    var visibleReadingSessions: [ReadingSessionGroup] {
        // Snapshot phase changes independently of the cached durable groups.
        let activeID = snapshot.phase == .paused ? nil : snapshot.sessionID
        if let cached = visibleSessionGroupsCache, cached.activeID == activeID { return cached.groups }
        let groups = readingSessions
        if durableVisibleSessionIDs == nil {
            durableVisibleSessionIDs = Set(ReadingSessionGrouping.visibleGroups(groups, events: events, merges: merges,
                correctedIntervalIDs: correctedIntervalIDs).map(\.id))
        }
        let visible = groups.filter { group in
            durableVisibleSessionIDs!.contains(group.id) ||
                (activeID.map { id in group.intervals.contains { $0.sessionID == id } } ?? false)
        }
        visibleSessionGroupsCache = (activeID, visible)
        return visible
    }
    var readingSessions: [ReadingSessionGroup] {
        if let cached = sessionGroupsCache { return cached }
        let groups = ReadingSessionGrouping.groups(intervals: intervals, merges: merges, breakBeforeIntervalIDs: sessionBreakIDs)
        sessionGroupsCache = groups
        return groups
    }

    init(support: URL, defaults: UserDefaults = .standard, startTracking: Bool = true,
         accessibilityStatus: @escaping () -> Bool = { BooksCapture.isTrusted },
         historyReader: @escaping (URL) throws -> (archive: HistoryArchive, intervals: [ReadingInterval]) = ReadingStore.readSnapshot,
         makeTrackingEngine: @escaping (ReadingStore, String, TimeInterval) throws -> TrackingEngine = {
             try TrackingEngine(store: $0, timezoneID: $1, uncertaintyThreshold: $2)
         }) throws {
        self.historyReader = historyReader
        self.makeTrackingEngine = makeTrackingEngine
        self.accessibilityStatus = accessibilityStatus
        self.support = support
        self.defaults = defaults
        epubLibrary = EPUBLibraryController(directory: support.appendingPathComponent("Publications", isDirectory: true))
        epubReaders = EPUBReaderWindows(stateDirectory: support.appendingPathComponent("ReaderState", isDirectory: true))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        store = try ReadingStore(url: support.appendingPathComponent("history.sqlite"))
        let zone = defaults.string(forKey: "timezoneID").flatMap { TimeZone(identifier: $0) }?.identifier ?? TimeZone.current.identifier
        let uncertain = defaults.object(forKey: "uncertaintyMinutes") as? Double ?? 20
        engine = try makeTrackingEngine(store, zone, max(1, uncertain) * 60)
        covers = try CoverCache(directory: support.appendingPathComponent("Covers"))
        captures = BooksCapture(covers: covers)
        accessibilityGranted = accessibilityStatus()
        timezoneID = zone
        uncertaintyMinutes = max(1, uncertain)
        trackingEnabled = defaults.object(forKey: "trackingEnabled") as? Bool ?? true
        discordEnabled = defaults.bool(forKey: "discordEnabled")
        discordApplicationID = defaults.string(forKey: "discordApplicationID") ?? ""
        discordAssetKey = defaults.string(forKey: "discordAssetKey") ?? ""
        automaticPublicCovers = defaults.bool(forKey: "automaticPublicCovers")
        syncAppleBooksHistoryEnabled = defaults.object(forKey: "syncAppleBooksHistoryEnabled") as? Bool ?? true
        suppressedHistoryIDs = Set(defaults.stringArray(forKey: "suppressedAppleHistory") ?? [])
        goalMinutes = defaults.object(forKey: "goalMinutes") as? Double ?? 20
        pageGoal = defaults.object(forKey: "pageGoal") as? Double ?? 20
        publicCoverURLs = defaults.dictionary(forKey: "publicCoverURLs") as? [String: String] ?? [:]
        savedGoal = goalMinutes
        savedPageGoal = pageGoal
        launchAtLogin = LoginService.enabled
        if try store.archive().goals.isEmpty {
            try store.setGoal(GoalChange(effectiveDay: ReadingStatistics.dayKey(Date(), timezoneID: zone), minutes: goalMinutes, pages: pageGoal, primaryUnit: dailyGoalUnit))
        }
        syncGoalFromHistory()
        try ensureCurrentPageGoal()
        ready = startTracking
        syncGoalFromHistory()
        if startTracking {
        registerObservers()
        windowObserver = BooksWindowObserver { [weak self] in
            guard let self else { return }
            self.captureGeneration += 1
            if self.manualBook == nil && self.epubReaders.focusedPublicationID == nil { self.pause(.noReadingWindow); self.tick() }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.tick() } }
        if !defaults.bool(forKey: "didConfigureLogin"), Bundle.main.bundleURL.pathExtension == "app" {
            defaults.set(true, forKey: "didConfigureLogin")
            do { try LoginService.setEnabled(true); launchAtLogin = LoginService.enabled }
            catch { errorMessage = "Login startup needs setup: \(error.localizedDescription). Enable it in Settings after installing the app." }
        }
        tick()
        } else { refresh(); refreshDiscordStatus() }
        epubReaders.didFocusReader = { [weak self] in self?.cancelExternalCoverLookups(); self?.tick() }
        epubReaders.positionChanged = { [weak self] in self?.tick() }
        epubReaders.positionFinalized = { [weak self] progress in
            guard let self, self.ready, self.trackingEnabled, self.manualBook == nil else { return }
            do {
                try self.engine.recordPosition(progress)
                self.requestHistoryRefresh()
            } catch { self.trackingFailure(error) }
        }
        epubReaders.traversedContent = { [weak self] bookID, evidence in self?.recordNativeCoverage(bookID: bookID, evidence: evidence) }
        epubReaders.libraryRequested = { [weak self] in self?.showDashboard(section: .library) }
        epubLibrary.register = { [weak self] publication, directory in
            try self?.registerPublication(publication, directory: directory)
        }
        epubLibrary.didImport = { [weak self] publication in self?.pendingLinkOffers.append("epub:" + publication.id) }
        epubLibrary.didFinishQueue = { [weak self] in
            guard let self else { return }
            let ids = self.pendingLinkOffers; self.pendingLinkOffers = []
            self.offerLinks(for: ids)
        }
        epubLibrary.didRecover = { [weak self] in
            guard let self else { return }
            self.offerLinks(for: self.books.filter { $0.source == "stillleaf-epub" }.map(\.id))
        }
        epubLibrary.presentLibrary = { [weak self] in
            self?.dashboardSectionRequest = .library
            self?.dashboardAction?()
        }
        audiobookPlayer.timezoneID = { [weak self] in self?.timezoneID ?? TimeZone.current.identifier }
        audiobookPlayer.willPlay = { [weak self] in
            guard let self else { return }
            guard !self.trackingRecoveryRequired else {
                throw ReadingStoreError.invalidData("Tracking is paused while the tracker recovers. Choose Try again in the dashboard, then retry playback.")
            }
            // Stop the reading tracker before the audio clock starts: no double credit.
            try self.stopForMutation()
            self.manualBook = nil
        }
        audiobookPlayer.shouldCredit = { [weak self] id in
            guard let self, let book = self.books.first(where: { $0.id == id }) else { return false }
            return self.trackingEnabled && !self.trackingRecoveryRequired && !book.trackingExcluded
        }
        audiobookPlayer.persist = { [weak self] observation, interval in
            guard let self, let book = self.books.first(where: { $0.id == observation.bookID }) else {
                throw ReadingStoreError.invalidData("The audiobook is no longer in this library.")
            }
            try self.store.saveAudiobook(book, progress: observation, interval: interval)
            self.refresh()
        }
        if startTracking { epubLibrary.recover() }
    }

    private func registerPublication(_ publication: EPUBPublication, directory: URL) throws {
        let id = "epub:" + publication.id
        var book = books.first(where: { $0.id == id }) ?? BookRecord(id: id, title: publication.title,
            author: publication.authors.isEmpty ? nil : publication.authors.joined(separator: ", "), source: "stillleaf-epub")
        // Preserve explicit user choices across a repeated import/recovery. This
        // path never consults Apple Books or a public artwork provider.
        if book.coverSource != "Manual override", let path = publication.coverPath {
            let cover = try? covers.explicitEPUBImage(from: directory.appendingPathComponent("resources").appendingPathComponent(path))
            book.coverPath = cover?.path; book.coverSource = cover?.source
        }
        try store.saveBook(book)
        refresh()
    }

    /// The Apple Books asset behind this journal book, directly or through a link.
    func appleBooksAssetID(for book: BookRecord) -> String? {
        let canonical = resolverID(book.id), prefix = "apple-books:"
        return books.first { $0.id.hasPrefix(prefix) && resolverID($0.id) == canonical }.map { String($0.id.dropFirst(prefix.count)) }
    }
    /// Whether this book's Apple Books copy can be opened here. Store purchases can't, so they
    /// get no read button; a book not yet checked is offered and explains itself if refused.
    func canReadAppleBooksCopy(_ book: BookRecord) -> Bool {
        guard let assetID = appleBooksAssetID(for: book) else { return false }
        return !appleBooksStorePurchaseIDs.contains(assetID)
    }
    /// Checks the journal's Apple Books books for store purchases off the main thread.
    private func refreshStorePurchases() {
        guard !storePurchaseCheckInFlight else { return }
        let prefix = "apple-books:"
        let assetIDs = Set(books.filter { $0.id.hasPrefix(prefix) }.map { String($0.id.dropFirst(prefix.count)) })
        guard !assetIDs.isEmpty else { return }
        storePurchaseCheckInFlight = true; lastStorePurchaseCheck = Date()
        historyQueue.async { [weak self] in
            let purchases = try? BooksCatalog().storePurchases(among: assetIDs)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.storePurchaseCheckInFlight = false
                if let purchases, purchases != self.appleBooksStorePurchaseIDs { self.appleBooksStorePurchaseIDs = purchases }
            }
        }
    }
    /// Books the reader added to Apple Books are kept there as readable EPUBs. Import that copy,
    /// link it to this journal book so history counts once, and open it. Store purchases are
    /// refused by the importer's protection check and stay in Apple Books.
    func readFromAppleBooks(_ book: BookRecord) {
        guard let assetID = appleBooksAssetID(for: book), preparingAppleBooksIDs.insert(book.id).inserted else { return }
        let canonical = resolverID(book.id)
        epubLibrary.importFromAppleBooks(assetID: assetID) { [weak self] result in
            guard let self else { return }
            self.preparingAppleBooksIDs.remove(book.id)
            switch result {
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                // A refused store purchase loses its read button now rather than on the next check.
                self.refreshStorePurchases()
            case .success(let publication):
                let editionID = "epub:" + publication.id
                if self.resolverID(editionID) != canonical, let edition = self.books.first(where: { $0.id == editionID }),
                   let target = self.books.first(where: { $0.id == canonical }) {
                    self.mergeBooks(source: edition, target: target)
                }
                if let target = self.books.first(where: { $0.id == canonical }), self.hasEPUB(target) { self.readEPUB(target) }
            }
        }
    }
    /// Offers to link fresh EPUB editions to a journal book with the same title and a compatible
    /// author, so reading time, goals and ratings count once. Never automatic, because a title
    /// alone is not proof of identity; a declined offer is not repeated.
    private func offerLinks(for ids: [String]) {
        guard ready, !ids.isEmpty, !epubReaders.isTerminating else { return }
        let declined = Set(defaults.stringArray(forKey: Self.declinedLinkOffersKey) ?? [])
        let resolver = BookMergeResolver(merges: merges)
        var pairs: [(edition: BookRecord, book: BookRecord)] = []
        for id in Set(ids).sorted() where !declined.contains(id) && resolver.resolvedID(for: id) == id {
            guard let edition = books.first(where: { $0.id == id }), edition.resolvedFormat == .text else { continue }
            let matches = books.filter { $0.resolvedFormat == .text && $0.id != id && $0.source != "stillleaf-epub" && resolver.resolvedID(for: $0.id) == $0.id && BookIdentity.sameWork(edition, $0) }
            if matches.count == 1 { pairs.append((edition, matches[0])) }
        }
        guard !pairs.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = pairs.count == 1 ? "Link this EPUB with “\(pairs[0].book.title)”?" : "Link \(pairs.count) EPUBs with books already in your journal?"
        let list = pairs.count == 1 ? "" : pairs.prefix(8).map { "• \($0.book.title)" }.joined(separator: "\n") + (pairs.count > 8 ? "\n…" : "") + "\n\n"
        alert.informativeText = list + "Linked books share one card, so reading time, goals and ratings from Apple Books and Stillleaf count together. Reading positions stay separate and Apple Books is never changed. You can unlink from the book’s details."
        alert.addButton(withTitle: "Link"); alert.addButton(withTitle: "Keep Separate")
        if alert.runModal() == .alertFirstButtonReturn {
            perform { try stopForMutation(); for pair in pairs { try store.merge(BookMerge(sourceID: pair.edition.id, targetID: pair.book.id)) } }
        } else {
            defaults.set(Array(declined.union(pairs.map { $0.edition.id })).sorted(), forKey: Self.declinedLinkOffersKey)
        }
    }
    private static let declinedLinkOffersKey = "declinedEPUBLinkOffers"
    func epubEditions(for book: BookRecord) -> [EPUBPublication] {
        let resolver = BookMergeResolver(merges: merges), canonicalID = resolverID(book.id)
        return epubLibrary.publications.values.filter { resolver.resolvedID(for: "epub:" + $0.id) == canonicalID }.sorted { $0.id < $1.id }
    }
    private func resolverID(_ id: String) -> String { BookMergeResolver(merges: merges).resolvedID(for: id) }
    func hasEPUB(_ book: BookRecord) -> Bool { !epubEditions(for: book).isEmpty }
    func hasImportedEPUB(_ book: BookRecord) -> Bool {
        let canonical = resolverID(book.id)
        return books.contains { $0.source == "stillleaf-epub" && resolverID($0.id) == canonical }
    }
    private func chooseEPUB(_ book: BookRecord) -> EPUBPublication? {
        guard !epubReaders.isTerminating else { return nil }
        let editions = epubEditions(for: book)
        guard !editions.isEmpty else { errorMessage = "This book’s EPUB is not available. Import it again to read here."; return nil }
        if editions.count == 1 { return editions[0] }
        let alert = NSAlert(); alert.messageText = "Choose an EPUB edition"
        alert.informativeText = "Each edition keeps its own reading position and notes. The short identifier distinguishes copies with the same title."
        let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        choice.addItems(withTitles: editions.map { "\($0.title) · \($0.spine.count) sections · \($0.id.prefix(8))" })
        alert.accessoryView = choice; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return editions[choice.indexOfSelectedItem]
    }
    var hasNativeReaderCommands: Bool { epubReaders.hasCommandReader }
    func performReaderControl(_ command: String) { epubReaders.performControl(command) }
    func isOpeningEPUB(_ book: BookRecord) -> Bool {
        guard !openingEPUBIDs.isEmpty else { return false }
        let resolver = BookMergeResolver(merges: merges)
        let canonicalID = resolver.resolvedID(for: book.id)
        return openingEPUBIDs.contains { resolver.resolvedID(for: "epub:" + $0) == canonicalID }
    }
    func readEPUB(_ book: BookRecord) {
        guard !isOpeningEPUB(book), let publication = chooseEPUB(book), !epubLibrary.removingIDs.contains(publication.id),
              !transferringReaderState.contains(publication.id), openingEPUBIDs.insert(publication.id).inserted else { return }
        cancelExternalCoverLookups()
        Task {
            defer { openingEPUBIDs.remove(publication.id) }
            do { try await epubReaders.open(publication, directory: epubLibrary.directory.appendingPathComponent(publication.id)) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func removeEPUB(_ book: BookRecord, keepCopy: Bool) {
        guard let publication = chooseEPUB(book) else { return }
        let id = publication.id
        let remove: (URL?) -> Void = { [weak self] destination in
            guard let self else { return }
            guard !self.transferringReaderState.contains(id), self.epubLibrary.reserveRemoval(id) else { return }
            Task {
                guard await self.epubReaders.close(publicationID: id) else { self.epubLibrary.cancelRemoval(id); return }
                self.epubLibrary.remove(publicationID: id, keepingOriginalAt: destination) { [weak self] in self?.refresh() }
            }
        }
        if keepCopy {
            let panel = NSSavePanel()
            panel.title = "Keep a usable EPUB copy"
            panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
            panel.nameFieldStringValue = book.title.replacingOccurrences(of: "/", with: "-") + ".epub"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in remove(url) }
            }
        } else { remove(nil) }
    }
    func transferReaderState(_ book: BookRecord, importing: Bool) {
        guard let publication = chooseEPUB(book) else { return }
        let id = publication.id
        guard !epubLibrary.removingIDs.contains(id), transferringReaderState.insert(id).inserted else { return }
        let panel: NSSavePanel
        if importing {
            let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
            picker.title = "Import notes and reading settings"; panel = picker
        } else {
            panel = NSSavePanel(); panel.title = "Export notes and reading settings"
            panel.nameFieldStringValue = book.title.replacingOccurrences(of: "/", with: "-") + " — reading state.json"
        }
        panel.allowedContentTypes = [.json]
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { self.transferringReaderState.remove(id); return }
            Task { @MainActor in
                defer { self.transferringReaderState.remove(id) }
                guard await self.epubReaders.close(publicationID: id) else { return }
                let transfer = ReaderStateTransfer(store: ReaderStateStore(directory: self.support.appendingPathComponent("ReaderState")))
                do {
                    if importing {
                        let preview = try await Task.detached { try transfer.previewImport(from: url, publication: publication) }.value
                        if preview.disposition == .stale { throw ReaderStateTransferError.staleImport }
                        var replace = false
                        if preview.disposition == .replacement {
                            let alert = NSAlert()
                            alert.messageText = "Replace this book’s saved reading state?"
                            alert.informativeText = "Current: \(preview.localBookmarks) bookmarks and \(preview.localAnnotations) highlights or notes. Imported: \(preview.incomingBookmarks) bookmarks and \(preview.incomingAnnotations) highlights or notes. This replaces reading position and appearance settings too. Notes are not merged; export the current state first to keep both."
                            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Replace saved state")
                            guard alert.runModal() == .alertSecondButtonReturn else { return }
                            replace = true
                        }
                        let replacing = replace
                        _ = try await Task.detached { try transfer.apply(preview, replacingExisting: replacing) }.value
                    } else {
                        _ = try await Task.detached { try transfer.export(publication: publication, to: url) }.value
                    }
                } catch { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func prepareReaderTermination() async -> Bool {
        guard !importingAudio else { errorMessage = "Finish the audio import before quitting."; return false }
        guard transferringReaderState.isEmpty else { errorMessage = "Finish the reading-state file operation before quitting."; return false }
        do { try audiobookPlayer.pause() }
        catch { errorMessage = "Could not save the last listening checkpoint. Resolve the storage error, then try quitting again: \(error)"; return false }
        return await epubReaders.closeAll()
    }

    private func registerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == BooksCapture.bundleID else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureGeneration += 1
                self.readerWindow = nil
                self.presencePolicy.reset()
                if self.manualBook == nil && self.epubReaders.focusedPublicationID == nil { self.pause(.noReadingWindow) }
                else { self.publishPresence() }
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.captureGeneration += 1
                if self.manualBook == nil && self.epubReaders.focusedPublicationID == nil && !SystemEligibility.booksForeground { self.pause(.background) }
                self.tick()
            }
        })
        let pairs: [(Notification.Name, String, Bool, PauseReason)] = [
            (NSWorkspace.willSleepNotification, "sleep", true, .displayAsleep),
            (NSWorkspace.didWakeNotification, "sleep", false, .displayAsleep),
            (NSWorkspace.screensDidSleepNotification, "display", true, .displayAsleep),
            (NSWorkspace.screensDidWakeNotification, "display", false, .displayAsleep),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true, .locked),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session", false, .locked)
        ]
        for (name, key, stop, reason) in pairs {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.systemChanged(key: key, stopped: stop, reason: reason) }
            })
        }
        for (name, stop) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.systemChanged(key: "lock", stopped: stop, reason: .locked) }
            })
        }
    }
    private func systemChanged(key: String, stopped: Bool, reason: PauseReason) {
        captureGeneration += 1
        if stopped { audiobookPlayer.pauseReportingErrors(); suspended.insert(key); pause(reason) } else { suspended.remove(key); tick() }
    }
    private func commonPauseReason() -> PauseReason? {
        if trackingRecoveryRequired { return .captureFailure }
        if !trackingEnabled { return .disabled }
        if suspended.contains("lock") || suspended.contains("session") || !SystemEligibility.unlocked { return .locked }
        if !suspended.isEmpty || !SystemEligibility.displayAwake { return .displayAsleep }
        return nil
    }
    /// The tracker reports its status every second. Publishing identical text
    /// would invalidate every dashboard observing this model while idle.
    func reportHealth(_ message: String) {
        guard health != message else { return }
        health = message
    }

    private func tick() {
        guard ready, !trackingRecoveryRequired else { return }
        if Date().timeIntervalSince(lastHistorySync) > 30 { syncAppleBooksHistory() }
        if Date().timeIntervalSince(lastStorePurchaseCheck) > 60 { refreshStorePurchases() }
        let trusted = accessibilityStatus()
        if accessibilityGranted != trusted { accessibilityGranted = trusted }
        windowObserver?.refresh()
        if audiobookPlayer.isPlaying {
            if !suspended.isEmpty || !SystemEligibility.unlocked { audiobookPlayer.pauseReportingErrors() }
            else { return }
        }
        if let reason = commonPauseReason() { pause(reason); return }
        if epubReaders.focusedPublicationID != nil { cancelExternalCoverLookups() }
        switch readingTrackingSource {
        case .manual:
            guard let book = manualBook else { return }
            apply(book: book, progress: nil, mode: .manual, reason: book.trackingExcluded ? .excludedBook : nil, health: "Manual reading is active. Time is inferred until you stop or pause.")
            return
        case .nativeReader:
            guard let edition = epubReaders.focusedPublicationID, let book = books.first(where: { $0.id == "epub:" + edition }) else {
                pause(.noReadingWindow); return
            }
            cancelExternalCoverLookups()
            captureGeneration += 1
            readerWindow = nil
            apply(book: book, progress: epubReaders.focusedProgress, mode: .automatic, reason: book.trackingExcluded ? .excludedBook : nil,
                  health: "Reading in Stillleaf. Position comes from the reader; sequential content coverage and active time are recorded separately.")
            return
        case .appleBooksNeedsAccess:
            reportHealth("Apple Books tracking needs Accessibility access. Import an EPUB into Stillleaf to record reading progress and time without it.")
            pause(.permissionLost); return
        case .idle:
            reportHealth("Ready to read in Stillleaf. Import an EPUB to record progress and active reading time without Accessibility access.")
            // Input in Discord or another app is not evidence of reading.
            lastInputUptime = ProcessInfo.processInfo.systemUptime - SystemEligibility.secondsSinceInput
            pause(.background); return
        case .appleBooks:
            break
        }
        if captureInFlight {
            if Date().timeIntervalSince(captureStarted) > 2 { reportHealth("Books capture is delayed; tracking is paused until fresh evidence arrives."); pause(.captureFailure) }
            return
        }
        captureInFlight = true; captureStarted = Date()
        let generation = captureGeneration
        captureQueue.async { [weak self, captures] in
            let result = captures.capture()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.captureInFlight = false
                guard generation == self.captureGeneration, self.manualBook == nil, !self.audiobookPlayer.isPlaying, self.commonPauseReason() == nil, SystemEligibility.booksForeground else { self.pageTurnTracker.reset(); self.readerPagination.reset(); return }
                guard Date().timeIntervalSince(result.observedAt) < 3 else { self.pause(.captureFailure); return }
                var book = result.book
                if var incoming = book, let existing = self.books.first(where: { $0.id == incoming.id }) {
                    incoming.trackingExcluded = existing.trackingExcluded; incoming.sharingExcluded = existing.sharingExcluded
                    if existing.coverSource == "Manual override" || incoming.coverPath == nil || (existing.coverSource == "Apple Books associated artwork" && incoming.coverSource == "Unprotected EPUB embedded cover") { incoming.coverPath = existing.coverPath; incoming.coverSource = existing.coverSource }
                    incoming.format = existing.format; incoming.audioFileName = existing.audioFileName
                    book = incoming
                }
                self.lastCapture = result.pauseReason == nil ? result.observedAt : self.lastCapture
                self.readerWindow = result.book == nil ? nil : result.readerWindow
                self.apply(book: book, progress: result.progress, mode: .automatic, reason: book?.trackingExcluded == true ? .excludedBook : result.pauseReason, health: result.health, navigationToken: result.navigationToken, pagePosition: result.pagePosition)
            }
        }
    }
    private func apply(book: BookRecord?, progress: ProgressObservation?, mode: ReadingMode, reason: PauseReason?, health: String, navigationToken: String? = nil, pagePosition: ReaderPagePosition? = nil) {
        let progressChanged = progress.map { value in
            latestProgress.map { prior in
                value.bookID != prior.bookID || value.page != prior.page || value.totalPages != prior.totalPages
                    || value.fraction != prior.fraction || value.location != prior.location
                    || value.source != prior.source || value.reliable != prior.reliable
            } ?? true
        } ?? false
        reportHealth(health); latestProgress = progress
        let uptime = ProcessInfo.processInfo.systemUptime
        let sampleDate = Date()
        let latestInput = uptime - SystemEligibility.secondsSinceInput
        let relevant = latestInput > lastInputUptime + 0.05
        lastInputUptime = latestInput
        let previousPhase = snapshot.phase
        let previousBookID = snapshot.book?.id
        do {
            var readingActivity = relevant
            if let book, reason == nil, !book.trackingExcluded {
                hasPageNavigationSignal = navigationToken != nil
                readingActivity = readingActivityEvidence.observe(bookID: book.id, navigationToken: navigationToken, relevantActivity: relevant)
                presencePolicy.observe(bookID: book.id, navigationToken: navigationToken, relevantActivity: relevant, uptime: uptime)
            }
            try engine.process(TrackingInput(date: sampleDate, uptime: uptime, book: book, mode: mode, pauseReason: reason, relevantActivity: readingActivity, progress: progress))
            snapshot = engine.snapshot
            var recordedPageTurn = false
            if mode == .automatic, reason == nil, let book, book.source != "stillleaf-epub", let sessionID = snapshot.sessionID,
               snapshot.phase != .paused {
                if let evidence = observePagePosition(pagePosition, bookID: book.id, sessionID: sessionID,
                                                      date: sampleDate, uptime: uptime) {
                    // Commit its supporting interval before storing the page event.
                    try engine.checkpoint(date: sampleDate, uptime: uptime)
                    snapshot = engine.snapshot
                    try store.appendEvent(AuditEvent(date: sampleDate, kind: "pageTurn", bookID: book.id, sessionID: sessionID,
                        detail: "Observed forward page movement between nearby samples in a stable reader layout.", pageTurn: evidence))
                    recordedPageTurn = true
                }
            } else { pageTurnTracker.reset(); readerPagination.reset(); currentPagePosition = nil }
            recordHealth(reason, verifiedCapture: mode == .automatic && book != nil && book?.source != "stillleaf-epub" && reason == nil)
            if recordedPageTurn || progressChanged || Date().timeIntervalSince(lastRefresh) >= 15 || previousPhase != snapshot.phase || previousBookID != snapshot.book?.id { requestHistoryRefresh() }
            if let book, reason == nil { resolvePublicCoverIfNeeded(for: book) }
            publishPresence()
        } catch { trackingFailure(error) }
    }
    private func recordNativeCoverage(bookID: String, evidence: PageTurnEvidence) {
        guard ready, manualBook == nil, commonPauseReason() == nil,
              epubReaders.focusedPublicationID.map({ "epub:" + $0 }) == bookID else { return }
        let previousSession = snapshot.book?.id == bookID ? snapshot.sessionID : nil
        tick()
        guard let sessionID = previousSession, snapshot.sessionID == sessionID,
              snapshot.phase != .paused, snapshot.book?.trackingExcluded == false else { return }
        do {
            let date = Date(), uptime = ProcessInfo.processInfo.systemUptime
            try engine.checkpoint(date: date, uptime: uptime)
            snapshot = engine.snapshot
            guard snapshot.phase != .paused else { return }
            try store.appendEvent(AuditEvent(date: date, kind: "pageTurn", bookID: bookID, sessionID: sessionID,
                detail: "Native sequential navigation over the supplied chapter text range; not a comprehension claim.", pageTurn: evidence))
            requestHistoryRefresh()
        } catch { trackingFailure(error) }
    }

    /// A brief missing footer during a page animation is not a tracking pause.
    /// Both helpers still expire their baselines after five seconds.
    func observePagePosition(_ position: ReaderPagePosition?, bookID: String, sessionID: String,
                             date: Date, uptime: TimeInterval) -> PageTurnEvidence? {
        guard let position else { currentPagePosition = nil; return nil }
        currentPagePosition = readerPagination.observe(bookID: bookID, sessionID: sessionID,
                                                       position: position, uptime: uptime)
        guard let resolved = currentPagePosition else { pageTurnTracker.reset(); return nil }
        return pageTurnTracker.observe(bookID: bookID, sessionID: sessionID, position: resolved, date: date, uptime: uptime)
    }

    private func pause(_ reason: PauseReason) {
        pageTurnTracker.reset()
        readerPagination.reset()
        let changed = snapshot.phase != .paused || snapshot.pauseReason != reason
        do {
            // Processing ineligibility preserves brief interruption grouping without crediting the gap.
            try engine.process(TrackingInput(mode: manualBook == nil ? .automatic : .manual, pauseReason: reason))
            if changed { snapshot = engine.snapshot }
            recordHealth(reason)
            if changed || today.day != ReadingStatistics.dayKey(Date(), timezoneID: timezoneID) { requestHistoryRefresh() }
        } catch { trackingFailure(error) }
        publishPresence()
    }
    private func recordHealth(_ reason: PauseReason?, verifiedCapture: Bool = false) {
        // Switching away from Books is not evidence that missing access recovered.
        let isFailure = reason == .permissionLost || reason == .captureFailure
        guard (isFailure && reason != lastHealthReason) || (verifiedCapture && lastHealthReason != nil) else { return }
        do {
            try store.appendEvent(AuditEvent(kind: isFailure ? "trackingGap" : "trackingAccessRestored", detail: isFailure ? reason!.rawValue : "capture restored"))
            lastHealthReason = isFailure ? reason : nil
        } catch { errorMessage = "Could not persist data health: \(error)" }
    }
    private func trackingFailure(_ error: Error) {
        errorMessage = "Tracking stopped because evidence could not be saved: \(error)"
        reportHealth("Storage requires attention. New time is not being credited.")
        ready = false; timer?.invalidate(); presencePolicy.reset(); presenceState = .hidden; discord.clear()
    }
    private func publishPresence() {
        if snapshot.book?.source == "stillleaf-epub" {
            finishPublishingPresence(readerOpen: epubReaders.focusedPublicationID != nil && commonPauseReason() == nil)
            return
        }
        guard trackingEnabled, discordEnabled, accessibilityGranted, commonPauseReason() == nil,
              let window = readerWindow else { finishPublishingPresence(readerOpen: false); return }
        guard !readerCheckInFlight else { return }
        readerCheckInFlight = true
        readerCheckQueue.async { [weak self] in
            let isOpen = window.isOpen
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readerCheckInFlight = false
                guard self.readerWindow === window else { return }
                self.finishPublishingPresence(readerOpen: isOpen && self.accessibilityGranted && self.commonPauseReason() == nil)
            }
        }
    }
    private func finishPublishingPresence(readerOpen: Bool) {
        let currentBook = snapshot.book.flatMap { current in books.first { $0.id == current.id } ?? current }
        presenceState = presencePolicy.state(for: snapshot, book: currentBook, enabled: trackingEnabled && discordEnabled,
                                             readerOpen: readerOpen,
                                             uptime: ProcessInfo.processInfo.systemUptime)
        let visible = presenceState != .hidden
        rememberDiscordResult()
        discord.update(book: visible ? currentBook : nil, progress: latestProgress?.reliable == true ? latestProgress : nil,
                       elapsed: snapshot.sessionSeconds, enabled: discordEnabled && visible,
                       applicationID: discordApplicationID, assetKey: discordAssetKey, paused: presenceState == .paused,
                       coverURL: currentBook.flatMap { $0.source == "stillleaf-epub" ? nil : publicCoverURLs[$0.id] }, currentPage: currentPage,
                       currentTotalPages: currentTotalPages, pagesTurned: sessionPages)
        refreshDiscordStatus()
    }
    private func rememberDiscordResult() {
        let status = discord.status
        if status == "Discord activity shared" || status.contains("rejected") || status.contains("unavailable") || status.contains("connection closed") || status.contains("connection lost") {
            if lastDiscordResult != status { lastDiscordResult = status }
        }
    }
    private func refreshDiscordStatus() {
        rememberDiscordResult()
        let status: String
        if !discordEnabled { status = "Discord sharing is off." }
        else if discordNeedsSetup { status = "Discord application ID needed." }
        else if snapshot.book?.sharingExcluded == true { status = "This book is excluded from Discord sharing." }
        else if presenceState == .hidden { status = "Waiting for reading activity in Books." }
        else { status = discord.status }
        if discordStatus != status { discordStatus = status }
    }
    /// Opt-in diagnostics from the actual GUI process, whose macOS permission may differ from a CLI helper.
    func writeStatusReport(to url: URL) throws {
        let report: [String: Any] = [
            "processID": ProcessInfo.processInfo.processIdentifier,
            "observedAt": ISO8601DateFormatter().string(from: Date()),
            "accessibilityGranted": accessibilityGranted,
            "trackingEnabled": trackingEnabled,
            "booksForeground": SystemEligibility.booksForeground,
            "phase": snapshot.phase.rawValue,
            "pauseReason": snapshot.pauseReason?.rawValue ?? "none",
            "hasMatchedBook": snapshot.book != nil,
            "sessionSeconds": snapshot.sessionSeconds,
            "savedIntervalCount": intervals.count,
            "lastCapture": lastCapture.map { ISO8601DateFormatter().string(from: $0) } ?? "none",
            "health": health,
            "discordEnabled": discordEnabled,
            "discordIDConfigured": !discordApplicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "discordPresenceState": discordEnabled ? presenceState.rawValue : "hidden",
            "hasPageNavigationSignal": hasPageNavigationSignal,
            "todayPages": todayPages,
            "sessionPages": sessionPages,
            "hasPagePosition": currentPage != nil,
            "currentPage": currentPage.map { $0 as Any } ?? NSNull(),
            "currentTotalPages": currentTotalPages.map { $0 as Any } ?? NSNull(),
            "hasPublicCover": snapshot.book.flatMap { publicCoverURLs[$0.id] }.flatMap(PublicBookCover.publicImageURL) != nil,
            "finishedBookCount": finishedBooks.count,
            "historySyncEnabled": syncAppleBooksHistoryEnabled,
            "automaticPublicCovers": automaticPublicCovers,
            "discordActivityAcknowledged": discordStatus == "Discord activity shared",
            "lastDiscordActivityAcknowledged": lastDiscordResult == "Discord activity shared"
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    // Only the worker owns its read connection. The tracking store stays on the main actor.
    private let refreshQueue = DispatchQueue(label: "Stillleaf.history-presentation", qos: .userInitiated)
    private var refreshGeneration = 0
    private var refreshInFlight = false
    private var refreshPending = false
    private var refreshStopped = false
    var historyRefreshIsIdle: Bool { !refreshInFlight && !refreshPending }

    /// Reader-driven requests coalesce without starving publication during continuous reading.
    /// Serial results may trail live progress; explicit edits invalidate them via refreshGeneration.
    func requestHistoryRefresh() {
        guard !refreshStopped else { return }
        if refreshInFlight { refreshPending = true; return }
        startHistoryRefresh()
    }

    private func startHistoryRefresh() {
        refreshInFlight = true
        refreshPending = false
        let generation = refreshGeneration
        let zone = timezoneID, fallbackGoal = goalMinutes
        let day = ReadingStatistics.dayKey(Date(), timezoneID: zone)
        let locale = Locale.current.identifier
        let systemZone = TimeZone.current.identifier
        let systemCalendar = Calendar.current
        let url = support.appendingPathComponent("history.sqlite")
        let read = historyReader
        refreshQueue.async { [weak self] in
            let result = Result {
                let source = try read(url)
                return HistoryPresentation(archive: source.archive, effectiveIntervals: source.intervals,
                    timezoneID: zone, goalMinutes: fallbackGoal)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshInFlight = false
                guard !self.refreshStopped else { return }
                if generation == self.refreshGeneration {
                    if zone == self.timezoneID, fallbackGoal == self.goalMinutes,
                       day == ReadingStatistics.dayKey(Date(), timezoneID: zone),
                       locale == Locale.current.identifier, systemZone == TimeZone.current.identifier,
                       systemCalendar == Calendar.current {
                        switch result {
                        case .success(let prepared): self.applyHistory(prepared); self.publishPresence()
                        case .failure(let error): self.errorMessage = "Cannot read local history: \(error)"
                        }
                    } else { self.refreshPending = true }
                }
                if self.refreshPending { self.startHistoryRefresh() }
            }
        }
    }

    /// Explicit edits retain immediate read-after-write behavior and supersede queued reads.
    func refresh(recoverTracking: Bool = true) {
        refreshGeneration += 1
        refreshPending = false
        if recoverTracking, trackingRecoveryRequired, !rebuildingTracker {
            do { try resetEngineAfterMutation(); errorMessage = nil }
            catch { /* The recovery status remains visible without masquerading as a failed save. */ }
        }
        do {
            let archive = try store.archive()
            applyHistory(HistoryPresentation(archive: archive, effectiveIntervals: try store.effectiveIntervals(),
                timezoneID: timezoneID, goalMinutes: goalMinutes))
        } catch { errorMessage = "Cannot read local history: \(error)" }
    }

    private func applyHistory(_ prepared: HistoryPresentation) {
        librarySummary = prepared.librarySummary
        displayedIntervalsCache = nil; sessionGroupsCache = nil
        durableVisibleSessionIDs = nil; visibleSessionGroupsCache = nil
        bookPaceCache.removeAll(keepingCapacity: true); sessionPaceCache.removeAll(keepingCapacity: true)
        bookPagesCache.removeAll(keepingCapacity: true); sessionPagesCache.removeAll(keepingCapacity: true)
        books = prepared.books
        intervals = prepared.intervals
        events = prepared.events
        bookRatings = prepared.bookRatings
        bookReviewCache = prepared.bookReviewCache
        bookReviewDates = prepared.bookReviewDates
        progress = prepared.progress
        merges = prepared.merges
        libraryPositions = prepared.libraryPositions
        correctedIntervalIDs = prepared.correctedIntervalIDs
        sessionBreakIDs = prepared.sessionBreakIDs
        days = prepared.days
        today = prepared.today
        streak = prepared.streak
        pageEvidenceCache = prepared.pageEvidence
        pageDays = prepared.pageDays
        pageDaysByKey = prepared.pageDaysByKey
        todayPages = prepared.todayPages
        pageStreak = prepared.pageStreak
        goalHistory = prepared.goalHistory
        goalProgressByDay = prepared.goalProgressByDay
        dailyGoalStreak = prepared.dailyGoalStreak
        annualBookGoal = prepared.annualBookGoal
        annualBooksFinished = prepared.annualBooksFinished
        finishedBooks = prepared.finishedBooks
        historyAtlasSource = prepared.atlasSource
        sessionPages = snapshot.sessionID.map { pages(forSessionID: $0) } ?? 0
        if let pending = pendingCompletion { pendingCompletion = finishedBooks.first { $0.id == pending.id } }
        lastRefresh = Date()
    }
    private func syncGoalFromHistory() {
        guard let archive = try? store.archive() else { return }
        let todayKey = ReadingStatistics.dayKey(Date(), timezoneID: timezoneID)
        let matching = archive.goals.enumerated().filter { $0.element.effectiveDay <= todayKey }
        if let latest = matching.max(by: { a, b in a.element.effectiveDay == b.element.effectiveDay ? a.offset < b.offset : a.element.effectiveDay < b.element.effectiveDay })?.element {
            dailyGoalUnit = latest.resolvedUnit; savedDailyGoalUnit = dailyGoalUnit
            goalMinutes = latest.minutes; savedGoal = latest.minutes; defaults.set(latest.minutes, forKey: "goalMinutes")
            if let pages = latest.pages { pageGoal = pages; savedPageGoal = pages; defaults.set(pages, forKey: "pageGoal") }
        }
    }
    private func ensureCurrentPageGoal() throws {
        let todayKey = ReadingStatistics.dayKey(Date(), timezoneID: timezoneID)
        let goals = try store.archive().goals.enumerated().filter { $0.element.effectiveDay <= todayKey }
        let current = goals.max { lhs, rhs in
            lhs.element.effectiveDay == rhs.element.effectiveDay ? lhs.offset < rhs.offset : lhs.element.effectiveDay < rhs.element.effectiveDay
        }?.element
        if current?.pages == nil {
            try store.setGoal(GoalChange(effectiveDay: todayKey, minutes: goalMinutes, pages: pageGoal, primaryUnit: dailyGoalUnit))
        }
    }
    func pages(on dayKey: String) -> Int { pageDaysByKey[dayKey]?.pages ?? 0 }
    func pageGoal(on dayKey: String) -> Int? { pageDaysByKey[dayKey]?.goalPages.map(Int.init) }
    var pagePace: Double? {
        sessionPagesPerMinute.map { 1 / $0 }
    }
    var sessionPagesPerMinute: Double? {
        guard let sessionID = snapshot.sessionID else { return nil }
        if let cached = sessionPaceCache[sessionID] { return cached.value }
        let pace = PageStatistics.pagesPerMinute(events: events, effectiveIntervals: intervals, merges: merges, sessionID: sessionID)
        sessionPaceCache[sessionID] = CachedPace(value: pace)
        return pace
    }
    func pagesPerMinute(forBookID bookID: String) -> Double? {
        if let cached = bookPaceCache[bookID] { return cached.value }
        let pace = PageStatistics.pagesPerMinute(events: events, effectiveIntervals: intervals, merges: merges, bookID: bookID)
        bookPaceCache[bookID] = CachedPace(value: pace)
        return pace
    }
    func pages(from: Date, through: Date) -> Int {
        pageEvidence.pages(from: from, through: through)
    }
    func pages(forBookID bookID: String) -> Int {
        if let cached = bookPagesCache[bookID] { return cached }
        let count = pageEvidence.pages(bookID: bookID)
        bookPagesCache[bookID] = count
        return count
    }
    func pages(forBookID bookID: String, from: Date, through: Date) -> Int {
        pageEvidence.pages(from: from, through: through, bookID: bookID)
    }
    func pages(in group: ReadingSessionGroup, from: Date? = nil, through: Date? = nil) -> Int {
        pageEvidence.pages(from: from, through: through, bookID: group.bookID, within: group.intervals)
    }
    func pages(forSessionID sessionID: String) -> Int {
        if let cached = sessionPagesCache[sessionID] { return cached }
        let count = pageEvidence.pages(sessionID: sessionID)
        sessionPagesCache[sessionID] = count
        return count
    }
    func manualPages(forBookID bookID: String) -> Int {
        PageStatistics.manualPages(events: events, effectiveIntervals: intervals, merges: merges, bookID: bookID)
    }
    func manualPages(in group: ReadingSessionGroup, from: Date? = nil, through: Date? = nil) -> Int {
        PageStatistics.manualPages(events: events, effectiveIntervals: group.intervals, merges: merges,
                                   from: from, through: through, bookID: group.bookID)
    }
    func publicCoverURL(for book: BookRecord) -> String { book.source == "stillleaf-epub" ? "" : publicCoverURLs[book.id] ?? "" }
    func savePublicCoverURL(_ value: String, for book: BookRecord) {
        guard book.source != "stillleaf-epub" else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { publicCoverURLs.removeValue(forKey: book.id) }
        else if let url = PublicBookCover.publicImageURL(trimmed) { publicCoverURLs[book.id] = url }
        else { errorMessage = "Use a public HTTPS image link ending in .jpg, .png, .webp or .gif, without sign-in details or query parameters."; return }
        defaults.set(publicCoverURLs, forKey: "publicCoverURLs")
        errorMessage = nil; publishPresence()
    }
    private func resolvePublicCoverIfNeeded(for book: BookRecord) {
        guard book.source != "stillleaf-epub", epubReaders.focusedPublicationID == nil, automaticPublicCovers, discordEnabled, !book.sharingExcluded,
              publicCoverURLs[book.id] == nil, !coverLookups.contains(book.id),
              Date().timeIntervalSince(coverLookupDates[book.id] ?? .distantPast) > 3600 else { return }
        coverLookups.insert(book.id); coverLookupDates[book.id] = Date()
        let generation = coverLookupGeneration
        coverLookupTasks[book.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.coverLookupGeneration {
                    self.coverLookups.remove(book.id); self.coverLookupTasks.removeValue(forKey: book.id)
                }
            }
            do {
                if let match = try await self.publicCoverResolver.resolve(book: book),
                   !Task.isCancelled, generation == self.coverLookupGeneration, self.epubReaders.focusedPublicationID == nil,
                   self.automaticPublicCovers, self.discordEnabled,
                   let current = self.books.first(where: { $0.id == book.id }), !current.sharingExcluded,
                   self.publicCoverURLs[book.id] == nil {
                    self.savePublicCoverURL(match.url, for: current)
                }
            } catch { /* A missing public cover never interrupts local reading. */ }
        }
    }
    private func cancelExternalCoverLookups() {
        guard !coverLookupTasks.isEmpty else { return }
        coverLookupGeneration += 1
        for (id, task) in coverLookupTasks { task.cancel(); coverLookupDates.removeValue(forKey: id) }
        coverLookupTasks.removeAll(); coverLookups.removeAll()
    }
    @discardableResult
    func markFinished(_ book: BookRecord) -> FinishedBookEntry? {
        let canonicalID = BookMergeResolver(merges: merges).resolvedID(for: book.id)
        guard books.contains(where: { $0.id == canonicalID }) else {
            errorMessage = "This book is no longer in your library."; return nil
        }
        if let existing = finishedBooks.first(where: { $0.id == canonicalID }) { return existing }
        let now = Date()
        let event = AuditEvent(date: now, kind: "bookCompleted", bookID: canonicalID,
            detail: "Marked finished by the reader.",
            completion: BookCompletionEvidence(finishedAt: now, source: "You", imported: false))
        perform { try store.appendEvent(event) }
        guard errorMessage == nil, let entry = finishedBooks.first(where: { $0.id == canonicalID }) else { return nil }
        pendingCompletionEventID = event.id
        pendingCompletion = entry
        return entry
    }

    /// Correct saved evidence without creating another completion prompt or celebration.
    /// The editor owns its draft; failures leave the saved evidence untouched.
    func saveReadingDates(_ dates: ReadingCompletionDates, for bookID: String) -> String? {
        let canonicalID = BookMergeResolver(merges: merges).resolvedID(for: bookID)
        guard let existing = finishedBooks.first(where: { $0.id == canonicalID }) else {
            return "This book is no longer marked as read."
        }
        if existing.startedAt == dates.startedAt, existing.finishedAt == dates.finishedAt { return nil }
        let now = Date()
        if let message = dates.validationMessage(now: now) { return message }
        let event = AuditEvent(date: now, kind: "bookCompleted", bookID: canonicalID,
            detail: "Reading dates edited by the reader; no reading activity inferred.",
            completion: BookCompletionEvidence(startedAt: dates.startedAt, finishedAt: dates.finishedAt,
                                               source: "You", imported: false))
        perform { try store.appendEvent(event) }
        return errorMessage
    }

    func rating(for bookID: String) -> Double? { bookRatings[bookID] }
    func saveRating(_ rating: Double?, for bookID: String) {
        guard books.contains(where: { $0.id == bookID }),
              rating.map({ $0.isFinite && $0 >= 0 && $0 <= 5 && ($0 * 4).rounded() == $0 * 4 }) ?? true else {
            errorMessage = "Choose a rating from 0 to 5 in quarter-star steps."; return
        }
        perform { try store.appendEvent(AuditEvent(kind: "bookRated", bookID: bookID,
            detail: rating == nil ? "Rating cleared by the reader." : "Rating chosen by the reader.", rating: BookRatingEvidence(value: rating))) }
        if errorMessage == nil, pendingCompletion?.id == bookID { pendingCompletion = nil }
    }
    func review(for bookID: String) -> String? { bookReviewCache[bookID] }
    func reviewUpdatedAt(for bookID: String) -> Date? { bookReviewDates[bookID] }
    func saveReview(_ text: String?, for bookID: String) {
        guard books.contains(where: { $0.id == bookID }), (text?.count ?? 0) <= 50_000 else {
            errorMessage = "Keep your review within 50,000 characters."; return
        }
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let review = value?.isEmpty == false ? value : nil
        perform { try store.appendEvent(AuditEvent(kind: "bookReviewed", bookID: bookID,
            detail: review == nil ? "Written review cleared by the reader." : "Local written review saved by the reader.",
            review: BookReviewEvidence(text: review))) }
    }
    func claimCompletionCelebration(for entry: FinishedBookEntry) -> Bool {
        guard pendingCompletion?.id == entry.id, let eventID = pendingCompletionEventID else { return false }
        return celebratedCompletionIDs.insert(eventID).inserted
    }
    func acknowledgeCompletion(_ entry: FinishedBookEntry) {
        if pendingCompletion?.id == entry.id { pendingCompletion = nil }
    }
    nonisolated private static func historyKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func syncAppleBooksHistory() {
        guard syncAppleBooksHistoryEnabled, !historySyncInFlight else { return }
        historySyncInFlight = true; lastHistorySync = Date()
        let generation = historyGeneration
        let knownBooks = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        let suppressed = suppressedHistoryIDs
        historyQueue.async { [weak self] in
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("BooksPresence-history-\(UUID().uuidString)", isDirectory: true)
            do {
                let stagedCovers = try CoverCache(directory: staging)
                var imported = try BooksCatalog().finishedBooks()
                imported.removeAll { suppressed.contains(Self.historyKey($0.book.id)) }
                for index in imported.indices {
                    let book = imported[index].book
                    if let existing = knownBooks[book.id], existing.coverPath != nil {
                        imported[index].book = existing
                    } else if let asset = imported[index].assetURL,
                              let cover = try? stagedCovers.cover(bookID: book.id, assetURL: asset) {
                        imported[index].book.coverPath = cover.path
                        imported[index].book.coverSource = cover.source
                    }
                }
                let records = imported
                DispatchQueue.main.async { [weak self] in
                    defer { try? FileManager.default.removeItem(at: staging) }
                    guard let self else { return }
                    self.historySyncInFlight = false
                    guard self.historyGeneration == generation, self.syncAppleBooksHistoryEnabled else { return }
                    self.acceptFinishedHistory(records, staging: staging)
                }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                let description = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.historySyncInFlight = false
                    guard self?.historyGeneration == generation else { return }
                    self?.appleHistoryStatus = "Apple Books history unavailable: \(description)"
                }
            }
        }
    }
    /// Internal seam for synthetic integration checks; callers own staged-file cleanup.
    func acceptFinishedHistory(_ records: [CatalogFinishedBook], staging: URL) {
        guard syncAppleBooksHistoryEnabled else { return }
        do {
            let previousSync = defaults.object(forKey: "lastAppleHistorySync") as? Date
            let archive = try store.archive()
            var latestImported: [String: BookCompletionEvidence] = [:]
            for event in archive.events.sorted(by: { $0.date < $1.date }) {
                if let id = event.bookID, let completion = event.completion, completion.imported {
                    latestImported[id] = completion
                }
            }
            var newestCompletionID: String?
            var newestCompletionEventID: String?
            var historyChanged = false
            let observedAt = Date()
            for record in records.sorted(by: { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }) {
                guard !suppressedHistoryIDs.contains(Self.historyKey(record.book.id)) else { continue }
                // A same-ID import can never reset exclusions or overwrite a manual cover.
                let existingBook = books.first(where: { $0.id == record.book.id })
                var book = existingBook ?? record.book
                if let stagedPath = record.book.coverPath,
                   URL(fileURLWithPath: stagedPath).deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL,
                   book.coverPath == nil || book.coverPath == stagedPath {
                    let destination = support.appendingPathComponent("Covers").appendingPathComponent(URL(fileURLWithPath: stagedPath).lastPathComponent)
                    let data = try Data(contentsOf: URL(fileURLWithPath: stagedPath))
                    try data.write(to: destination, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    book.coverPath = destination.path; book.coverSource = record.book.coverSource
                }
                if existingBook != book { try store.saveBook(book); historyChanged = true }
                let completion = BookCompletionEvidence(finishedAt: record.finishedAt, source: "Apple Books", imported: true)
                if let previous = latestImported[book.id], previous.source == completion.source {
                    switch (previous.finishedAt, completion.finishedAt) {
                    case (nil, nil): continue
                    case let (old?, new?) where abs(old.timeIntervalSince(new)) < 0.001: continue
                    default: break
                    }
                }
                let recentlyCompleted = latestImported[book.id] == nil
                    && !finishedBooks.contains(where: { $0.id == book.id })
                    && previousSync.map { previous in record.finishedAt.map { $0 >= previous } ?? false } == true
                let completionEvent = AuditEvent(date: observedAt, kind: "bookCompleted", bookID: book.id,
                    detail: recentlyCompleted ? "Apple Books reported a newly finished book." : "Imported saved Apple Books completion metadata; no reading time or pages inferred.",
                    completion: completion)
                try store.appendEvent(completionEvent)
                historyChanged = true
                if recentlyCompleted { newestCompletionID = book.id; newestCompletionEventID = completionEvent.id }
            }
            defaults.set(observedAt, forKey: "lastAppleHistorySync")
            if historyChanged { refresh() }
            if let id = newestCompletionID { pendingCompletionEventID = newestCompletionEventID; pendingCompletion = finishedBooks.first { $0.id == id } }
            appleHistoryStatus = "Synced \(records.count) finished books from Apple Books."
        } catch { appleHistoryStatus = "Could not save Apple Books history: \(error.localizedDescription)" }
    }
    @discardableResult
    private func perform(afterCommit: (() throws -> Void)? = nil, _ action: () throws -> Void) -> Bool {
        refreshGeneration += 1; refreshPending = false
        do { try action() }
        catch { errorMessage = String(describing: error); return false }
        errorMessage = nil
        // The record is durable now. A failed tracker rebuild must not invite
        // another save with new record IDs or stale correction inputs.
        do { try afterCommit?() }
        catch { /* The mutation committed; resetEngineAfterMutation publishes recovery status separately. */ }
        refresh(recoverTracking: false)
        return true
    }
    private func resetEngineAfterMutation() throws {
        rebuildingTracker = true
        defer { rebuildingTracker = false }
        do {
            try audiobookPlayer.close()
            engine = try makeTrackingEngine(store, timezoneID, uncertaintyMinutes * 60)
            snapshot = engine.snapshot
            trackingRecoveryRequired = false
            trackingRecoveryMessage = nil
        } catch {
            trackingRecoveryRequired = true
            trackingRecoveryMessage = "Your saved changes are intact. Tracking is paused because the tracker could not recover. Choose Try again to retry recovery. \(error)"
            snapshot.phase = .paused; snapshot.pauseReason = .captureFailure
            presencePolicy.reset(); presenceState = .hidden; discord.clear()
            throw error
        }
    }
    private func stopForMutation() throws {
        refreshGeneration += 1; refreshPending = false
        try audiobookPlayer.pause()
        captureGeneration += 1
        historyGeneration += 1
        try engine.stop(); snapshot = engine.snapshot; pageTurnTracker.reset(); readerPagination.reset(); currentPagePosition = nil; readingActivityEvidence = ReadingActivityEvidence(); presencePolicy.reset(); presenceState = .hidden; discord.clear()
    }
    @discardableResult
    func startManual(title: String, author: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "Enter a book title."; return false }
        return startManual(book: BookRecord(id: "manual:\(UUID().uuidString)", title: trimmed, author: author.isEmpty ? nil : author))
    }
    @discardableResult
    func startManual(book: BookRecord) -> Bool {
        guard !trackingRecoveryRequired else {
            errorMessage = "Tracking is paused while the tracker recovers. Choose Try again in the dashboard, then start manual reading."
            return false
        }
        guard perform({ try stopForMutation(); try store.saveBook(book); manualBook = book }) else { return false }
        tick()
        return true
    }
    func stopManual() { perform { try stopForMutation(); manualBook = nil }; tick() }
    func canonicalLibraryBook(_ book: BookRecord) -> BookRecord? {
        let id = resolverID(book.id)
        return books.first { $0.id == id }
    }
    var libraryProgressObservations: [String: ProgressObservation] {
        libraryPositions
    }

    func audiobookProgress(for bookID: String) -> AudiobookProgress? {
        // Content positions belong to a particular edition, even when reading histories are linked.
        progress.enumerated().filter { $0.element.bookID == bookID && $0.element.audio != nil }
            .max { lhs, rhs in
                lhs.element.observedAt == rhs.element.observedAt ? lhs.offset < rhs.offset : lhs.element.observedAt < rhs.element.observedAt
            }?.element.audio
    }

    func isListening(_ interval: ReadingInterval) -> Bool {
        interval.mode == .listening || interval.audioSessionID != nil || progress.contains {
            $0.audio != nil && $0.bookID == interval.bookID && $0.sessionID == interval.sessionID
        }
    }

    func audiobookProgress(in group: ReadingSessionGroup) -> AudiobookProgress? {
        return progress.filter { observation in
            guard observation.audio != nil else { return false }
            return group.intervals.contains { interval in
                observation.bookID == interval.bookID &&
                observation.sessionID == (interval.audioSessionID ?? interval.sessionID) &&
                observation.observedAt > interval.start && observation.observedAt <= interval.end
            }
        }.max { $0.observedAt < $1.observedAt }?.audio
    }

    func setBookFormat(_ format: BookFormat, for book: BookRecord) {
        guard let book = canonicalLibraryBook(book) else { errorMessage = "This book is no longer in your library."; return }
        guard format != .text || book.audioFileName == nil else { errorMessage = "Remove the local audio file before switching to text."; return }
        perform {
            try stopForMutation()
            var updated = books.first(where: { $0.id == book.id }) ?? book
            updated.format = format; updated.observedAt = Date()
            try store.saveBook(updated)
        }
    }

    /// Saves to a specific library ID; never derives elapsed time from a position delta.
    @discardableResult
    func logAudiobook(book: BookRecord?, title: String = "", author: String = "", audio: AudiobookProgress,
                      start: Date?, end: Date) -> Bool {
        return perform(afterCommit: resetEngineAfterMutation) {
            guard audio.isValid, end <= Date(), start.map({ $0 < end }) ?? true else {
                throw ReadingStoreError.invalidData("Use a position within the total duration and a past session ending after its start.")
            }
            try stopForMutation()
            var record: BookRecord
            if let book {
                guard let existing = canonicalLibraryBook(book) else {
                    throw ReadingStoreError.invalidData("This book is no longer in your library.")
                }
                record = existing
            } else {
                record = BookRecord(id: "manual:" + UUID().uuidString, title: title.trimmingCharacters(in: .whitespacesAndNewlines), author: author.isEmpty ? nil : author)
            }
            record.format = .audiobook; record.observedAt = Date()
            let sessionID = UUID().uuidString
            let interval = start.map { ReadingInterval(sessionID: sessionID, bookID: record.id,
                start: $0, end: end, duration: end.timeIntervalSince($0), timezoneID: timezoneID, mode: .manual, audioSessionID: sessionID) }
            let observation = ProgressObservation(bookID: record.id, observedAt: end, fraction: audio.fraction,
                source: "manual-audio", reliable: true, audio: audio, sessionID: interval?.sessionID)
            if audiobookPlayer.bookID == record.id { try audiobookPlayer.close() }
            try store.saveAudiobook(record, progress: observation, interval: interval)
        }
    }

    func chooseAudiobook(for book: BookRecord? = nil) {
        guard !importingAudio else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = LocalAudiobook.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Import one unprotected local audio file. Stillleaf keeps a copy; your original stays where it is."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importAudiobook(url, for: book) }
    }

    func importAudiobook(_ url: URL, for book: BookRecord? = nil) async {
        guard !importingAudio else { return }
        importingAudio = true
        defer { importingAudio = false }
        let directory = support.appendingPathComponent("Audiobooks", isDirectory: true)
        var imported: LocalAudiobook.Imported?
        do {
            let result = try await Task.detached(priority: .userInitiated) { try LocalAudiobook.copy(from: url, to: directory) }.value
            imported = result
            try stopForMutation()
            var record: BookRecord
            if let book {
                guard let existing = canonicalLibraryBook(book) else {
                    throw ReadingStoreError.invalidData("This book was removed while its audio was importing.")
                }
                record = existing
            } else {
                record = BookRecord(id: "audio:" + UUID().uuidString, title: url.deletingPathExtension().lastPathComponent, source: "local-audio")
            }
            let previousFile = record.audioFileName
            record.format = .audiobook; record.audioFileName = result.fileName; record.observedAt = Date()
            let saved = audiobookProgress(for: record.id)
            let resume = saved.flatMap { abs($0.durationSeconds - result.duration) <= max(1, result.duration * 0.01) ? min($0.positionSeconds, result.duration) : nil } ?? 0
            let audio = AudiobookProgress(positionSeconds: resume, durationSeconds: result.duration)
            if audiobookPlayer.bookID == record.id { try audiobookPlayer.close() }
            try store.saveAudiobook(record, progress: ProgressObservation(bookID: record.id, fraction: audio.fraction, source: "local-audio", reliable: true, audio: audio))
            if let previousFile { try? FileManager.default.trashItem(at: directory.appendingPathComponent(previousFile), resultingItemURL: nil) }
            refresh(); errorMessage = nil
        } catch {
            if let imported { try? FileManager.default.removeItem(at: directory.appendingPathComponent(imported.fileName)) }
            errorMessage = "Could not import audio: \(error). Choose an unprotected file supported by macOS."
        }
    }

    func openAudiobook(_ book: BookRecord) {
        guard let book = canonicalLibraryBook(book) else { errorMessage = "This book is no longer in your library."; return }
        do {
            guard let file = book.audioFileName else { return }
            if audiobookPlayer.bookID != book.id {
                try audiobookPlayer.load(book: book, url: support.appendingPathComponent("Audiobooks").appendingPathComponent(file),
                    resume: audiobookProgress(for: book.id)?.positionSeconds ?? 0)
            }
            errorMessage = nil
        } catch { errorMessage = "The audio copy is missing or unreadable. Import the local file again. \(error)" }
    }

    func removeAudiobook(_ book: BookRecord) {
        guard let book = canonicalLibraryBook(book) else { errorMessage = "This book is no longer in your library."; return }
        perform {
            try stopForMutation()
            if audiobookPlayer.bookID == book.id { try audiobookPlayer.close() }
            var updated = book; updated.audioFileName = nil; updated.observedAt = Date()
            try store.saveBook(updated)
            if let file = book.audioFileName {
                let url = support.appendingPathComponent("Audiobooks").appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            }
        }
    }

    @discardableResult
    func addManual(title: String, author: String, start: Date, end: Date) -> Bool {
        guard end > start, end <= Date(), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "Manual records need a title and a past end time after the start."; return false }
        return perform(afterCommit: resetEngineAfterMutation) {
            try stopForMutation()
            let book = BookRecord(id: "manual:\(UUID().uuidString)", title: title, author: author.isEmpty ? nil : author)
            var archive = HistoryArchive(); archive.books = [book]
            archive.intervals = [ReadingInterval(sessionID: UUID().uuidString, bookID: book.id, start: start, end: end, duration: end.timeIntervalSince(start), timezoneID: timezoneID, mode: .manual)]
            archive.events = [AuditEvent(kind: "manualAddition", bookID: book.id, sessionID: archive.intervals[0].sessionID, detail: "User-entered reading time; elapsed duration supplied manually.")]
            try importArchive(archive)
        }
    }
    private func importArchive(_ archive: HistoryArchive) throws {
        let url = support.appendingPathComponent(".import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(archive).write(to: url, options: .atomic)
        try store.importJSON(from: url)
    }
    func requestAccessibility() { BooksCapture.requestAccess(); refreshAccessibilityStatus(); openAccessibilitySettings() }
    /// Access is granted in System Settings, outside the app; views that wait on it poll here.
    func refreshAccessibilityStatus() {
        let trusted = accessibilityStatus()
        if accessibilityGranted != trusted { accessibilityGranted = trusted }
    }

    static let onboardingCompletedKey = "onboardingCompleted"
    var onboardingAction: (() -> Void)?
    var needsOnboarding: Bool { !defaults.bool(forKey: Self.onboardingCompletedKey) }
    func markOnboardingComplete() { defaults.set(true, forKey: Self.onboardingCompletedKey) }
    func showOnboarding() { onboardingAction?() }
    /// Saves the welcome tour's goal choice through the same validated path as Settings.
    func applyOnboardingGoals(unit: DailyGoalUnit, pages: Int, minutes: Int, annualBooks: Int?) {
        dailyGoalUnit = unit
        pageGoal = Double(pages)
        goalMinutes = Double(minutes)
        annualBookGoal = annualBooks
        saveSettings()
    }
    func openAccessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    func saveSettings() {
        guard annualBookGoal.map({ (1...10_000).contains($0) }) ?? true,
              pageGoal.isFinite, pageGoal >= 1, pageGoal <= 10_000, pageGoal.rounded() == pageGoal,
              goalMinutes.isFinite, goalMinutes >= 1, goalMinutes <= 1440, TimeZone(identifier: timezoneID) != nil, uncertaintyMinutes.isFinite, uncertaintyMinutes >= 1, uncertaintyMinutes <= 240 else { errorMessage = "Choose a whole-page goal from 1–10,000, a time goal from 1–1440 minutes, a valid timezone, and an uncertainty threshold from 1–240 minutes."; return }
        perform {
            let timezoneChanged = engine.timezoneID != timezoneID
            if timezoneChanged { try stopForMutation() }
            let calendarChange = timezoneChanged ? AuditEvent(kind: "calendarTimezoneChanged", detail: timezoneID) : nil
            let dailyChanged = savedGoal != goalMinutes || savedPageGoal != pageGoal || savedDailyGoalUnit != dailyGoalUnit
            let daily = dailyChanged ? GoalChange(effectiveDay: ReadingStatistics.dayKey(Date(), timezoneID: timezoneID),
                minutes: goalMinutes, pages: pageGoal, primaryUnit: dailyGoalUnit) : nil
            let annualChanged = ReadingGoals.annualTarget(year: goalYear, events: try store.archive().events) != annualBookGoal
            let annual = annualChanged ? AuditEvent(kind: "annualGoalChanged", detail: "Yearly books goal chosen by the reader.",
                annualGoal: AnnualGoalEvidence(year: goalYear, books: annualBookGoal)) : nil
            try store.setReadingGoals(daily: daily, annual: annual, calendarChange: calendarChange)
            engine.timezoneID = timezoneID
            engine.uncertaintyThreshold = uncertaintyMinutes * 60
            savedGoal = goalMinutes; savedPageGoal = pageGoal; savedDailyGoalUnit = dailyGoalUnit
            defaults.set(pageGoal, forKey: "pageGoal")
            defaults.set(goalMinutes, forKey: "goalMinutes"); defaults.set(timezoneID, forKey: "timezoneID"); defaults.set(uncertaintyMinutes, forKey: "uncertaintyMinutes")
            defaults.set(discordApplicationID, forKey: "discordApplicationID"); defaults.set(discordAssetKey, forKey: "discordAssetKey")
            defaults.set(automaticPublicCovers, forKey: "automaticPublicCovers")
            defaults.set(syncAppleBooksHistoryEnabled, forKey: "syncAppleBooksHistoryEnabled")
        }
        // Show the actual registration state even if macOS rejected a change.
        launchAtLogin = LoginService.enabled
        publishPresence()
        if let book = snapshot.book { resolvePublicCoverIfNeeded(for: book) }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { try LoginService.setEnabled(enabled); errorMessage = nil }
        catch { errorMessage = "Could not change Open at login: \(error.localizedDescription)" }
        launchAtLogin = LoginService.enabled
    }
    func setBookExclusions(_ book: BookRecord, tracking: Bool, sharing: Bool) {
        perform {
            if audiobookPlayer.bookID == book.id && book.trackingExcluded != tracking { try audiobookPlayer.pause() }
            var updated = book; updated.observedAt = Date(); updated.trackingExcluded = tracking; updated.sharingExcluded = sharing
            try store.saveBook(updated)
            if manualBook?.id == book.id { manualBook = updated }
            if snapshot.book?.id == book.id && book.trackingExcluded != tracking { try stopForMutation() }
        }
        publishPresence(); tick()
    }
    func chooseCover(for book: BookRecord) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let cover = try covers.manualImage(from: url, bookID: book.id)
            var updated = book; updated.observedAt = Date(); updated.coverPath = cover.path; updated.coverSource = cover.source
            try store.saveBook(updated)
            if manualBook?.id == book.id { manualBook = updated }
        }
    }
    @discardableResult
    func reviewInterval(_ interval: ReadingInterval, start: Date, end: Date, bookID: String, disposition: IntervalDisposition) -> Bool {
        guard end > start, end <= Date() else { errorMessage = "Use an end time after the start and no later than now."; return false }
        return perform(afterCommit: resetEngineAfterMutation) {
            try stopForMutation()
            // Unchanged bounds retain measured elapsed time; adjusted bounds are an explicit manual correction.
            let unchanged = abs(start.timeIntervalSince(interval.start)) < 0.001 && abs(end.timeIntervalSince(interval.end)) < 0.001
            let duration = unchanged ? interval.duration : end.timeIntervalSince(start)
            let revised = ReadingInterval(sessionID: interval.sessionID, bookID: bookID, start: start, end: end, duration: duration, timezoneID: interval.timezoneID, mode: unchanged ? interval.mode : .manual, disposition: disposition, audioSessionID: interval.audioSessionID ?? (isListening(interval) ? interval.sessionID : nil))
            try store.correct(IntervalCorrection(originalIDs: originalIDs(for: interval), replacements: [revised], reason: "User reviewed timing, assignment or credit status."))
        }
    }
    @discardableResult
    func splitInterval(_ interval: ReadingInterval, at date: Date) -> Bool {
        guard date > interval.start, date < interval.end else { errorMessage = "Split time must be inside this interval."; return false }
        return perform(afterCommit: resetEngineAfterMutation) {
            try stopForMutation()
            let fraction = date.timeIntervalSince(interval.start) / interval.end.timeIntervalSince(interval.start)
            let first = ReadingInterval(sessionID: interval.sessionID, bookID: interval.bookID, start: interval.start, end: date, duration: interval.duration * fraction, timezoneID: interval.timezoneID, mode: interval.mode, disposition: interval.disposition, audioSessionID: interval.audioSessionID ?? (isListening(interval) ? interval.sessionID : nil))
            let second = ReadingInterval(sessionID: UUID().uuidString, bookID: interval.bookID, start: date, end: interval.end, duration: interval.duration * (1 - fraction), timezoneID: interval.timezoneID, mode: interval.mode, disposition: interval.disposition, audioSessionID: interval.audioSessionID ?? (isListening(interval) ? interval.sessionID : nil))
            try store.correct(IntervalCorrection(originalIDs: originalIDs(for: interval), replacements: [first, second], reason: "User split a reading interval into two sessions."))
        }
    }
    func resolveUncertain(_ interval: ReadingInterval, confirm: Bool) { reviewInterval(interval, start: interval.start, end: interval.end, bookID: interval.bookID, disposition: confirm ? .credited : .excluded) }
    @discardableResult
    func deleteSession(_ sessionID: String) -> Bool { perform(afterCommit: resetEngineAfterMutation) { try stopForMutation(); defer { try? removeManagedBackups() }; try store.deleteSession(sessionID) } }
    func deleteBook(_ book: BookRecord) {
        perform {
            try stopForMutation(); if manualBook?.id == book.id { manualBook = nil }
            defer { try? removeManagedBackups() }
            if audiobookPlayer.bookID == book.id { try audiobookPlayer.close() }
            try store.deleteBook(book.id)
            if let file = book.audioFileName {
                let url = support.appendingPathComponent("Audiobooks").appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            }
            suppressedHistoryIDs.insert(Self.historyKey(book.id)); defaults.set(Array(suppressedHistoryIDs), forKey: "suppressedAppleHistory")
            publicCoverURLs.removeValue(forKey: book.id); defaults.set(publicCoverURLs, forKey: "publicCoverURLs")
            if pendingCompletion?.id == book.id { pendingCompletion = nil }
            try resetEngineAfterMutation(); try removeUnusedCovers()
        }
    }
    func deleteAllData() {
        guard !importingAudio else { errorMessage = "Finish the audio import before deleting all data."; return }
        trackingEnabled = false
        syncAppleBooksHistoryEnabled = false; defaults.set(false, forKey: "syncAppleBooksHistoryEnabled")
        perform {
            try stopForMutation(); try audiobookPlayer.close(); manualBook = nil; try store.deleteAll(); try resetEngineAfterMutation(); try removeManagedBackups()
            publicCoverURLs = [:]; defaults.removeObject(forKey: "publicCoverURLs")
            suppressedHistoryIDs = []; defaults.removeObject(forKey: "suppressedAppleHistory")
            defaults.removeObject(forKey: "lastAppleHistorySync"); pendingCompletion = nil
            let audioDirectory = support.appendingPathComponent("Audiobooks")
            if FileManager.default.fileExists(atPath: audioDirectory.path) { try FileManager.default.trashItem(at: audioDirectory, resultingItemURL: nil) }
            let coverDirectory = support.appendingPathComponent("Covers")
            if FileManager.default.fileExists(atPath: coverDirectory.path) { try FileManager.default.removeItem(at: coverDirectory); try FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true) }
        }
    }
    private func removeManagedBackups() throws {
        let directory = support.appendingPathComponent("Backups")
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func removeUnusedCovers() throws {
        let referenced = Set(try store.archive().books.compactMap(\.coverPath))
        let dir = support.appendingPathComponent("Covers")
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where !referenced.contains(file.path) { try FileManager.default.removeItem(at: file) }
    }
    @discardableResult
    func mergeBooks(source: BookRecord, target: BookRecord) -> Bool {
        guard source.resolvedFormat != .audiobook, target.resolvedFormat != .audiobook else {
            errorMessage = "Keep audiobook editions separate so their audio files and content positions remain accessible."
            return false
        }
        return perform { try stopForMutation(); try store.merge(BookMerge(sourceID: source.id, targetID: target.id)) } }
    func unmerge(_ merge: BookMerge) { perform { try stopForMutation(); try store.merge(BookMerge(sourceID: merge.sourceID, targetID: merge.targetID, active: false)) } }

    private func saveURL(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func openURL(types: [UTType]) -> URL? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = types; panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    func exportJSON() { guard let url = saveURL(name: "Stillleaf-history.json", type: .json) else { return }; perform { try engine.checkpoint(); try store.exportJSON(to: url) } }
    func importJSON() { guard let url = openURL(types: [.json]) else { return }; perform { try stopForMutation(); try store.importJSON(from: url); try resetEngineAfterMutation(); syncGoalFromHistory() } }
    func exportCSV() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Export tables here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        perform { try engine.checkpoint(); try store.exportCSV(to: dir.appendingPathComponent("Stillleaf-export-\(Int(Date().timeIntervalSince1970))")) }
    }
    func backup() { guard let url = saveURL(name: "Stillleaf-backup.sqlite", type: .database) else { return }; perform { try engine.checkpoint(); try store.backup(to: url) } }
    func restore() { guard !importingAudio else { errorMessage = "Finish the audio import before restoring history."; return }; guard let url = openURL(types: [.database, .data]) else { return }; perform { try stopForMutation(); try store.restore(from: url); try resetEngineAfterMutation(); syncGoalFromHistory(); try ensureCurrentPageGoal() } }
    func showDashboard(section: DashboardSection? = nil, settingsCategory: SettingsCategory? = nil) {
        if let section {
            if section == .settings { settingsCategoryRequest = settingsCategory }
            dashboardSectionRequest = section
        }
        dashboardAction?()
    }
    func quit() { NSApp.terminate(nil) }
    func shutdown() {
        refreshStopped = true; refreshGeneration += 1; refreshPending = false
        audiobookPlayer.pauseReportingErrors()
        ready = false
        cancelExternalCoverLookups()
        timer?.invalidate(); windowObserver?.invalidate(); captureGeneration += 1
        readerWindow = nil
        do { try engine.stop() } catch { NSLog("BooksPresence could not persist the final interval; previous checkpoints remain recoverable.") }
        discord.shutdown()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
    func uninstall() {
        perform {
            try LoginService.setEnabled(false)
            try stopForMutation(); trackingEnabled = false
            // Preserve history unless the separate delete-data control was used.
            guard Bundle.main.bundleURL.pathExtension == "app" else { throw BooksAccessError.unavailable("Quit and remove this development build manually. Login startup is disabled; history remains local.") }
            var result: NSURL?
            try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: &result)
            quit()
        }
    }
}

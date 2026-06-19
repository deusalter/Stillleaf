import AppKit
import SwiftUI
import BooksCore
import BooksPlatform
import UniformTypeIdentifiers
import CryptoKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = TrackerSnapshot()
    @Published private(set) var books: [BookRecord] = []
    @Published private(set) var intervals: [ReadingInterval] = []
    @Published private(set) var events: [AuditEvent] = []
    @Published private(set) var progress: [ProgressObservation] = []
    @Published private(set) var merges: [BookMerge] = []
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
    @Published private(set) var pendingCompletion: FinishedBookEntry?
    @Published private(set) var appleHistoryStatus = "Reading Apple Books history…"
    @Published private var publicCoverURLs: [String: String] = [:]
    @Published private(set) var health = "Starting the local tracker…"
    @Published private(set) var lastCapture: Date?
    @Published var errorMessage: String?
    @Published private(set) var discordStatus = "Discord sharing is off."
    @Published private(set) var lastDiscordResult: String?
    @Published private(set) var accessibilityGranted = BooksCapture.isTrusted
    var automaticTrackingNeedsAccess: Bool { trackingEnabled && !manualActive && !accessibilityGranted }
    var discordNeedsSetup: Bool { discordEnabled && discordApplicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @Published var trackingEnabled = true { didSet { if ready { defaults.set(trackingEnabled, forKey: "trackingEnabled"); if !trackingEnabled { pause(.disabled) } else { perform { try ensureCurrentPageGoal() } }; tick() } } }
    @Published var discordEnabled = false { didSet { if ready { defaults.set(discordEnabled, forKey: "discordEnabled"); publishPresence() } } }
    @Published var discordApplicationID = ""
    @Published var discordAssetKey = ""
    @Published var automaticPublicCovers = false
    @Published var syncAppleBooksHistoryEnabled = true
    @Published var goalMinutes: Double = 20
    @Published var pageGoal: Double = 20
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
    private let defaults: UserDefaults
    private let support: URL
    private let store: ReadingStore
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
    private var sessionBreakIDs: Set<String> = []
    var readingSessions: [ReadingSessionGroup] {
        if let cached = sessionGroupsCache { return cached }
        let groups = ReadingSessionGrouping.groups(intervals: intervals, merges: merges, breakBeforeIntervalIDs: sessionBreakIDs)
        sessionGroupsCache = groups
        return groups
    }

    init(support: URL, defaults: UserDefaults = .standard, startTracking: Bool = true) throws {
        self.support = support
        self.defaults = defaults
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        store = try ReadingStore(url: support.appendingPathComponent("history.sqlite"))
        let zone = defaults.string(forKey: "timezoneID").flatMap { TimeZone(identifier: $0) }?.identifier ?? TimeZone.current.identifier
        let uncertain = defaults.object(forKey: "uncertaintyMinutes") as? Double ?? 20
        engine = try TrackingEngine(store: store, timezoneID: zone, uncertaintyThreshold: max(1, uncertain) * 60)
        covers = try CoverCache(directory: support.appendingPathComponent("Covers"))
        captures = BooksCapture(covers: covers)
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
            try store.setGoal(GoalChange(effectiveDay: ReadingStatistics.dayKey(Date(), timezoneID: zone), minutes: goalMinutes, pages: pageGoal))
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
            if self.manualBook == nil { self.pause(.noReadingWindow); self.tick() }
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
                if self.manualBook == nil { self.pause(.noReadingWindow) }
                else { self.publishPresence() }
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.captureGeneration += 1
                if self.manualBook == nil && !SystemEligibility.booksForeground { self.pause(.background) }
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
        if stopped { suspended.insert(key); pause(reason) } else { suspended.remove(key); tick() }
    }
    private func commonPauseReason() -> PauseReason? {
        if !trackingEnabled { return .disabled }
        if suspended.contains("lock") || suspended.contains("session") || !SystemEligibility.unlocked { return .locked }
        if !suspended.isEmpty || !SystemEligibility.displayAwake { return .displayAsleep }
        return nil
    }
    private func tick() {
        guard ready else { return }
        if Date().timeIntervalSince(lastHistorySync) > 30 { syncAppleBooksHistory() }
        let trusted = BooksCapture.isTrusted
        if accessibilityGranted != trusted { accessibilityGranted = trusted }
        windowObserver?.refresh()
        if let reason = commonPauseReason() { pause(reason); return }
        if let book = manualBook { apply(book: book, progress: nil, mode: .manual, reason: book.trackingExcluded ? .excludedBook : nil, health: "Manual reading is active. Time is inferred until you stop or pause."); return }
        guard accessibilityGranted else { health = "Automatic tracking needs Accessibility access. Manual reading is available."; pause(.permissionLost); return }
        guard SystemEligibility.booksForeground else {
            // Input in Discord or another app is not evidence of reading.
            lastInputUptime = ProcessInfo.processInfo.systemUptime - SystemEligibility.secondsSinceInput
            pause(.background); return
        }
        if captureInFlight {
            if Date().timeIntervalSince(captureStarted) > 2 { health = "Books capture is delayed; tracking is paused until fresh evidence arrives."; pause(.captureFailure) }
            return
        }
        captureInFlight = true; captureStarted = Date()
        let generation = captureGeneration
        captureQueue.async { [weak self, captures] in
            let result = captures.capture()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.captureInFlight = false
                guard generation == self.captureGeneration, self.manualBook == nil, self.commonPauseReason() == nil, SystemEligibility.booksForeground else { self.pageTurnTracker.reset(); self.readerPagination.reset(); return }
                guard Date().timeIntervalSince(result.observedAt) < 3 else { self.pause(.captureFailure); return }
                var book = result.book
                if var incoming = book, let existing = self.books.first(where: { $0.id == incoming.id }) {
                    incoming.trackingExcluded = existing.trackingExcluded; incoming.sharingExcluded = existing.sharingExcluded
                    if existing.coverSource == "Manual override" || incoming.coverPath == nil || (existing.coverSource == "Apple Books associated artwork" && incoming.coverSource == "Unprotected EPUB embedded cover") { incoming.coverPath = existing.coverPath; incoming.coverSource = existing.coverSource }
                    book = incoming
                }
                self.lastCapture = result.pauseReason == nil ? result.observedAt : self.lastCapture
                self.readerWindow = result.book == nil ? nil : result.readerWindow
                self.apply(book: book, progress: result.progress, mode: .automatic, reason: book?.trackingExcluded == true ? .excludedBook : result.pauseReason, health: result.health, navigationToken: result.navigationToken, pagePosition: result.pagePosition)
            }
        }
    }
    private func apply(book: BookRecord?, progress: ProgressObservation?, mode: ReadingMode, reason: PauseReason?, health: String, navigationToken: String? = nil, pagePosition: ReaderPagePosition? = nil) {
        self.health = health; latestProgress = progress
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
            if mode == .automatic, reason == nil, let book, let sessionID = snapshot.sessionID,
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
            recordHealth(reason, verifiedCapture: mode == .automatic && book != nil && reason == nil)
            if recordedPageTurn || Date().timeIntervalSince(lastRefresh) >= 15 || previousPhase != snapshot.phase || previousBookID != snapshot.book?.id { refresh() }
            if let book, reason == nil { resolvePublicCoverIfNeeded(for: book) }
            publishPresence()
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
            if changed || today.day != ReadingStatistics.dayKey(Date(), timezoneID: timezoneID) { refresh() }
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
        health = "Storage requires attention. New time is not being credited."
        ready = false; timer?.invalidate(); presencePolicy.reset(); presenceState = .hidden; discord.clear()
    }
    private func publishPresence() {
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
                       coverURL: currentBook.flatMap { publicCoverURLs[$0.id] }, currentPage: currentPage,
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
    func refresh() {
        do {
            let archive = try store.archive()
            displayedIntervalsCache = nil; sessionGroupsCache = nil
            bookPaceCache.removeAll(keepingCapacity: true); sessionPaceCache.removeAll(keepingCapacity: true)
            bookPagesCache.removeAll(keepingCapacity: true); sessionPagesCache.removeAll(keepingCapacity: true)
            books = archive.books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            intervals = try store.effectiveIntervals().sorted { $0.start > $1.start }
            events = archive.events.sorted { $0.date > $1.date }
            progress = archive.progress.sorted { $0.observedAt > $1.observedAt }
            merges = archive.merges
            let splitSessions = Set(archive.corrections.flatMap { correction -> [String] in
                guard Set(correction.replacements.map(\.sessionID)).count > 1 else { return [] }
                return correction.replacements.sorted { $0.start < $1.start }.dropFirst().map(\.sessionID)
            })
            sessionBreakIDs = Set(splitSessions.compactMap { session in
                intervals.filter { $0.sessionID == session }.min { $0.start < $1.start }?.id
            })
            let earliest = min(intervals.map(\.start).min() ?? Date(), Calendar.current.date(byAdding: .day, value: -365, to: Date())!)
            days = ReadingStatistics.daily(intervals: intervals, goals: archive.goals, timezoneID: timezoneID, from: earliest, through: Date())
            let key = ReadingStatistics.dayKey(Date(), timezoneID: timezoneID)
            today = days.first { $0.day == key } ?? DailyTotal(day: key, creditedSeconds: 0, uncertainSeconds: 0, manualSeconds: 0, goalMinutes: goalMinutes)
            streak = ReadingStatistics.streak(days: days, today: key)
            pageDays = PageStatistics.daily(events: archive.events, effectiveIntervals: intervals, goals: archive.goals,
                merges: merges, timezoneID: timezoneID, from: earliest, through: Date())
            pageDaysByKey = Dictionary(uniqueKeysWithValues: pageDays.map { ($0.day, $0) })
            todayPages = pageDays.first { $0.day == key }?.pages ?? 0
            sessionPages = snapshot.sessionID.map { pages(forSessionID: $0) } ?? 0
            pageStreak = PageStatistics.streak(days: pageDays, today: key)
            finishedBooks = BookHistory.completedBooks(books: books, events: archive.events)
            if let pending = pendingCompletion { pendingCompletion = finishedBooks.first { $0.id == pending.id } }
            lastRefresh = Date()
        } catch { errorMessage = "Cannot read local history: \(error)" }
    }
    private func syncGoalFromHistory() {
        guard let archive = try? store.archive() else { return }
        let todayKey = ReadingStatistics.dayKey(Date(), timezoneID: timezoneID)
        let matching = archive.goals.enumerated().filter { $0.element.effectiveDay <= todayKey }
        if let latest = matching.max(by: { a, b in a.element.effectiveDay == b.element.effectiveDay ? a.offset < b.offset : a.element.effectiveDay < b.element.effectiveDay })?.element {
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
            try store.setGoal(GoalChange(effectiveDay: todayKey, minutes: goalMinutes, pages: pageGoal))
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
        PageStatistics.pages(events: events, effectiveIntervals: intervals, merges: merges, from: from, through: through)
    }
    func pages(forBookID bookID: String) -> Int {
        if let cached = bookPagesCache[bookID] { return cached }
        let count = PageStatistics.pages(events: events, effectiveIntervals: intervals, merges: merges, bookID: bookID)
        bookPagesCache[bookID] = count
        return count
    }
    func pages(forBookID bookID: String, from: Date, through: Date) -> Int {
        PageStatistics.pages(events: events, effectiveIntervals: intervals, merges: merges, from: from, through: through, bookID: bookID)
    }
    func pages(in group: ReadingSessionGroup, from: Date? = nil, through: Date? = nil) -> Int {
        PageStatistics.pages(events: events, effectiveIntervals: group.intervals, merges: merges, from: from, through: through, bookID: group.bookID)
    }
    func pages(forSessionID sessionID: String) -> Int {
        if let cached = sessionPagesCache[sessionID] { return cached }
        let count = PageStatistics.pages(events: events, effectiveIntervals: intervals, merges: merges, sessionID: sessionID)
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
    func publicCoverURL(for book: BookRecord) -> String { publicCoverURLs[book.id] ?? "" }
    func savePublicCoverURL(_ value: String, for book: BookRecord) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { publicCoverURLs.removeValue(forKey: book.id) }
        else if let url = PublicBookCover.publicImageURL(trimmed) { publicCoverURLs[book.id] = url }
        else { errorMessage = "Use a public HTTPS image link ending in .jpg, .png, .webp or .gif, without sign-in details or query parameters."; return }
        defaults.set(publicCoverURLs, forKey: "publicCoverURLs")
        errorMessage = nil; publishPresence()
    }
    private func resolvePublicCoverIfNeeded(for book: BookRecord) {
        guard automaticPublicCovers, discordEnabled, !book.sharingExcluded,
              publicCoverURLs[book.id] == nil, !coverLookups.contains(book.id),
              Date().timeIntervalSince(coverLookupDates[book.id] ?? .distantPast) > 3600 else { return }
        coverLookups.insert(book.id); coverLookupDates[book.id] = Date()
        Task { [weak self] in
            guard let self else { return }
            defer { self.coverLookups.remove(book.id) }
            do {
                if let match = try await self.publicCoverResolver.resolve(book: book),
                   self.automaticPublicCovers, self.discordEnabled,
                   let current = self.books.first(where: { $0.id == book.id }), !current.sharingExcluded,
                   self.publicCoverURLs[book.id] == nil {
                    self.savePublicCoverURL(match.url, for: current)
                }
            } catch { /* A missing public cover never interrupts local reading. */ }
        }
    }
    func rating(for bookID: String) -> Double? { BookHistory.rating(bookID: bookID, events: events) }
    func saveRating(_ rating: Double?, for bookID: String) {
        guard books.contains(where: { $0.id == bookID }),
              rating.map({ $0.isFinite && $0 >= 0 && $0 <= 5 && ($0 * 4).rounded() == $0 * 4 }) ?? true else {
            errorMessage = "Choose a rating from 0 to 5 in quarter-star steps."; return
        }
        perform { try store.appendEvent(AuditEvent(kind: "bookRated", bookID: bookID,
            detail: rating == nil ? "Rating cleared by the reader." : "Rating chosen by the reader.", rating: BookRatingEvidence(value: rating))) }
        if pendingCompletion?.id == bookID { pendingCompletion = nil }
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
                    && previousSync.map { previous in record.finishedAt.map { $0 >= previous } ?? false } == true
                try store.appendEvent(AuditEvent(date: observedAt, kind: "bookCompleted", bookID: book.id,
                    detail: recentlyCompleted ? "Apple Books reported a newly finished book." : "Imported saved Apple Books completion metadata; no reading time or pages inferred.",
                    completion: completion))
                historyChanged = true
                if recentlyCompleted { newestCompletionID = book.id }
            }
            defaults.set(observedAt, forKey: "lastAppleHistorySync")
            if historyChanged { refresh() }
            if let id = newestCompletionID { pendingCompletion = finishedBooks.first { $0.id == id } }
            appleHistoryStatus = "Synced \(records.count) finished books from Apple Books."
        } catch { appleHistoryStatus = "Could not save Apple Books history: \(error.localizedDescription)" }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil; refresh() }
        catch { errorMessage = String(describing: error) }
    }
    private func resetEngineAfterMutation() throws {
        engine = try TrackingEngine(store: store, timezoneID: timezoneID, uncertaintyThreshold: uncertaintyMinutes * 60)
        snapshot = engine.snapshot
    }
    private func stopForMutation() throws {
        captureGeneration += 1
        historyGeneration += 1
        try engine.stop(); snapshot = engine.snapshot; pageTurnTracker.reset(); readerPagination.reset(); currentPagePosition = nil; readingActivityEvidence = ReadingActivityEvidence(); presencePolicy.reset(); presenceState = .hidden; discord.clear()
    }
    func startManual(title: String, author: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "Enter a book title."; return }
        startManual(book: BookRecord(id: "manual:\(UUID().uuidString)", title: trimmed, author: author.isEmpty ? nil : author))
    }
    func startManual(book: BookRecord) {
        perform { try stopForMutation(); try store.saveBook(book); manualBook = book }
        tick()
    }
    func stopManual() { perform { try stopForMutation(); manualBook = nil }; tick() }
    func addManual(title: String, author: String, start: Date, end: Date) {
        guard end > start, end <= Date(), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "Manual records need a title and a past end time after the start."; return }
        perform {
            try stopForMutation()
            let book = BookRecord(id: "manual:\(UUID().uuidString)", title: title, author: author.isEmpty ? nil : author)
            var archive = HistoryArchive(); archive.books = [book]
            archive.intervals = [ReadingInterval(sessionID: UUID().uuidString, bookID: book.id, start: start, end: end, duration: end.timeIntervalSince(start), timezoneID: timezoneID, mode: .manual)]
            archive.events = [AuditEvent(kind: "manualAddition", bookID: book.id, sessionID: archive.intervals[0].sessionID, detail: "User-entered reading time; elapsed duration supplied manually.")]
            try importArchive(archive)
            try resetEngineAfterMutation()
        }
    }
    private func importArchive(_ archive: HistoryArchive) throws {
        let url = support.appendingPathComponent(".import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(archive).write(to: url, options: .atomic)
        try store.importJSON(from: url)
    }
    func requestAccessibility() { BooksCapture.requestAccess(); accessibilityGranted = BooksCapture.isTrusted; openAccessibilitySettings() }
    func openAccessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    func saveSettings() {
        guard pageGoal.isFinite, pageGoal >= 1, pageGoal <= 10_000, pageGoal.rounded() == pageGoal,
              goalMinutes.isFinite, goalMinutes >= 1, goalMinutes <= 1440, TimeZone(identifier: timezoneID) != nil, uncertaintyMinutes.isFinite, uncertaintyMinutes >= 1, uncertaintyMinutes <= 240 else { errorMessage = "Choose a whole-page goal from 1–10,000, a time goal from 1–1440 minutes, a valid timezone, and an uncertainty threshold from 1–240 minutes."; return }
        perform {
            if engine.timezoneID != timezoneID { try stopForMutation(); engine.timezoneID = timezoneID; try store.appendEvent(AuditEvent(kind: "calendarTimezoneChanged", detail: timezoneID)) }
            engine.uncertaintyThreshold = uncertaintyMinutes * 60
            if savedGoal != goalMinutes || savedPageGoal != pageGoal {
                try store.setGoal(GoalChange(effectiveDay: ReadingStatistics.dayKey(Date(), timezoneID: timezoneID), minutes: goalMinutes, pages: pageGoal))
                savedGoal = goalMinutes; savedPageGoal = pageGoal
            }
            defaults.set(pageGoal, forKey: "pageGoal")
            defaults.set(goalMinutes, forKey: "goalMinutes"); defaults.set(timezoneID, forKey: "timezoneID"); defaults.set(uncertaintyMinutes, forKey: "uncertaintyMinutes")
            defaults.set(discordApplicationID, forKey: "discordApplicationID"); defaults.set(discordAssetKey, forKey: "discordAssetKey")
            defaults.set(automaticPublicCovers, forKey: "automaticPublicCovers")
            defaults.set(syncAppleBooksHistoryEnabled, forKey: "syncAppleBooksHistoryEnabled")
            if LoginService.enabled != launchAtLogin { try LoginService.setEnabled(launchAtLogin) }
        }
        // Show the actual registration state even if macOS rejected a change.
        launchAtLogin = LoginService.enabled
        publishPresence()
        if let book = snapshot.book { resolvePublicCoverIfNeeded(for: book) }
    }
    func setBookExclusions(_ book: BookRecord, tracking: Bool, sharing: Bool) {
        perform {
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
    func reviewInterval(_ interval: ReadingInterval, start: Date, end: Date, bookID: String, disposition: IntervalDisposition) {
        guard end > start, end <= Date() else { errorMessage = "Use an end time after the start and no later than now."; return }
        perform {
            try stopForMutation()
            // Unchanged bounds retain measured elapsed time; adjusted bounds are an explicit manual correction.
            let unchanged = abs(start.timeIntervalSince(interval.start)) < 0.001 && abs(end.timeIntervalSince(interval.end)) < 0.001
            let duration = unchanged ? interval.duration : end.timeIntervalSince(start)
            let revised = ReadingInterval(sessionID: interval.sessionID, bookID: bookID, start: start, end: end, duration: duration, timezoneID: interval.timezoneID, mode: unchanged ? interval.mode : .manual, disposition: disposition)
            try store.correct(IntervalCorrection(originalIDs: originalIDs(for: interval), replacements: [revised], reason: "User reviewed timing, assignment or credit status."))
            try resetEngineAfterMutation()
        }
    }
    func splitInterval(_ interval: ReadingInterval, at date: Date) {
        guard date > interval.start, date < interval.end else { errorMessage = "Split time must be inside this interval."; return }
        perform {
            try stopForMutation()
            let fraction = date.timeIntervalSince(interval.start) / interval.end.timeIntervalSince(interval.start)
            let first = ReadingInterval(sessionID: interval.sessionID, bookID: interval.bookID, start: interval.start, end: date, duration: interval.duration * fraction, timezoneID: interval.timezoneID, mode: interval.mode, disposition: interval.disposition)
            let second = ReadingInterval(sessionID: UUID().uuidString, bookID: interval.bookID, start: date, end: interval.end, duration: interval.duration * (1 - fraction), timezoneID: interval.timezoneID, mode: interval.mode, disposition: interval.disposition)
            try store.correct(IntervalCorrection(originalIDs: originalIDs(for: interval), replacements: [first, second], reason: "User split a reading interval into two sessions."))
            try resetEngineAfterMutation()
        }
    }
    func resolveUncertain(_ interval: ReadingInterval, confirm: Bool) { reviewInterval(interval, start: interval.start, end: interval.end, bookID: interval.bookID, disposition: confirm ? .credited : .excluded) }
    func deleteSession(_ sessionID: String) { perform { try stopForMutation(); defer { try? removeManagedBackups() }; try store.deleteSession(sessionID); try resetEngineAfterMutation() } }
    func deleteBook(_ book: BookRecord) {
        perform {
            try stopForMutation(); if manualBook?.id == book.id { manualBook = nil }
            defer { try? removeManagedBackups() }
            try store.deleteBook(book.id)
            suppressedHistoryIDs.insert(Self.historyKey(book.id)); defaults.set(Array(suppressedHistoryIDs), forKey: "suppressedAppleHistory")
            publicCoverURLs.removeValue(forKey: book.id); defaults.set(publicCoverURLs, forKey: "publicCoverURLs")
            if pendingCompletion?.id == book.id { pendingCompletion = nil }
            try resetEngineAfterMutation(); try removeUnusedCovers()
        }
    }
    func deleteAllData() {
        trackingEnabled = false
        syncAppleBooksHistoryEnabled = false; defaults.set(false, forKey: "syncAppleBooksHistoryEnabled")
        perform {
            try stopForMutation(); manualBook = nil; try store.deleteAll(); try resetEngineAfterMutation(); try removeManagedBackups()
            publicCoverURLs = [:]; defaults.removeObject(forKey: "publicCoverURLs")
            suppressedHistoryIDs = []; defaults.removeObject(forKey: "suppressedAppleHistory")
            defaults.removeObject(forKey: "lastAppleHistorySync"); pendingCompletion = nil
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
    func mergeBooks(source: BookRecord, target: BookRecord) { perform { try stopForMutation(); try store.merge(BookMerge(sourceID: source.id, targetID: target.id)) } }
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
    func restore() { guard let url = openURL(types: [.database, .data]) else { return }; perform { try stopForMutation(); try store.restore(from: url); try resetEngineAfterMutation(); syncGoalFromHistory(); try ensureCurrentPageGoal() } }
    func showDashboard() { dashboardAction?() }
    func quit() { NSApp.terminate(nil) }
    func shutdown() {
        ready = false
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

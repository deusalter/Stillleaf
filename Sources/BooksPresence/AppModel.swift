import AppKit
import SwiftUI
import BooksCore
import BooksPlatform
import UniformTypeIdentifiers

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
    @Published private(set) var health = "Starting the local tracker…"
    @Published private(set) var lastCapture: Date?
    @Published var errorMessage: String?
    @Published private(set) var discordStatus = "Discord sharing is off."
    @Published private(set) var lastDiscordResult: String?
    @Published private(set) var accessibilityGranted = BooksCapture.isTrusted
    var automaticTrackingNeedsAccess: Bool { trackingEnabled && !manualActive && !accessibilityGranted }
    var discordNeedsSetup: Bool { discordEnabled && discordApplicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @Published var trackingEnabled = true { didSet { if ready { defaults.set(trackingEnabled, forKey: "trackingEnabled"); if !trackingEnabled { pause(.disabled) }; tick() } } }
    @Published var discordEnabled = false { didSet { if ready { defaults.set(discordEnabled, forKey: "discordEnabled"); publishPresence() } } }
    @Published var discordApplicationID = ""
    @Published var discordAssetKey = ""
    @Published var goalMinutes: Double = 20
    @Published var timezoneID = TimeZone.current.identifier
    @Published var uncertaintyMinutes: Double = 20
    @Published var launchAtLogin = false

    var displayIntervals: [ReadingInterval] {
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
        return result.sorted { $0.start > $1.start }
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
    private var savedGoal: Double = 20

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
        goalMinutes = defaults.object(forKey: "goalMinutes") as? Double ?? 20
        savedGoal = goalMinutes
        launchAtLogin = LoginService.enabled
        if try store.archive().goals.isEmpty {
            try store.setGoal(GoalChange(effectiveDay: ReadingStatistics.dayKey(Date(), timezoneID: zone), minutes: goalMinutes))
        }
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
        accessibilityGranted = BooksCapture.isTrusted
        windowObserver?.refresh()
        if let reason = commonPauseReason() { pause(reason); return }
        if let book = manualBook { apply(book: book, progress: nil, mode: .manual, reason: book.trackingExcluded ? .excludedBook : nil, health: "Manual reading is active. Time is inferred until you stop or pause."); return }
        guard SystemEligibility.booksForeground else { pause(.background); return }
        guard BooksCapture.isTrusted else { health = "Automatic tracking needs Accessibility access. Manual reading is available."; pause(.permissionLost); return }
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
                guard generation == self.captureGeneration, self.manualBook == nil, self.commonPauseReason() == nil, SystemEligibility.booksForeground else { return }
                guard Date().timeIntervalSince(result.observedAt) < 3 else { self.pause(.captureFailure); return }
                var book = result.book
                if var incoming = book, let existing = self.books.first(where: { $0.id == incoming.id }) {
                    incoming.trackingExcluded = existing.trackingExcluded; incoming.sharingExcluded = existing.sharingExcluded
                    if existing.coverSource == "Manual override" || incoming.coverPath == nil || (existing.coverSource == "Apple Books associated artwork" && incoming.coverSource == "Unprotected EPUB embedded cover") { incoming.coverPath = existing.coverPath; incoming.coverSource = existing.coverSource }
                    book = incoming
                }
                self.lastCapture = result.pauseReason == nil ? result.observedAt : self.lastCapture
                self.apply(book: book, progress: result.progress, mode: .automatic, reason: book?.trackingExcluded == true ? .excludedBook : result.pauseReason, health: result.health)
            }
        }
    }
    private func apply(book: BookRecord?, progress: ProgressObservation?, mode: ReadingMode, reason: PauseReason?, health: String) {
        self.health = health; latestProgress = progress
        let uptime = ProcessInfo.processInfo.systemUptime
        let latestInput = uptime - SystemEligibility.secondsSinceInput
        let relevant = latestInput > lastInputUptime + 0.05
        lastInputUptime = latestInput
        let previousPhase = snapshot.phase
        let previousBookID = snapshot.book?.id
        do {
            try engine.process(TrackingInput(book: book, mode: mode, pauseReason: reason, relevantActivity: relevant, progress: progress))
            snapshot = engine.snapshot
            recordHealth(reason, verifiedCapture: mode == .automatic && book != nil && reason == nil)
            if Date().timeIntervalSince(lastRefresh) >= 15 || previousPhase != snapshot.phase || previousBookID != snapshot.book?.id { refresh() }
            publishPresence()
        } catch { trackingFailure(error) }
    }
    private func pause(_ reason: PauseReason) {
        let changed = snapshot.phase != .paused || snapshot.pauseReason != reason
        do {
            // Processing ineligibility preserves brief interruption grouping without crediting the gap.
            try engine.process(TrackingInput(mode: manualBook == nil ? .automatic : .manual, pauseReason: reason))
            snapshot = engine.snapshot
            recordHealth(reason)
            if changed || today.day != ReadingStatistics.dayKey(Date(), timezoneID: timezoneID) { refresh() }
        } catch { trackingFailure(error) }
        if changed { rememberDiscordResult(); discord.clear() }
        refreshDiscordStatus()
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
        ready = false; timer?.invalidate(); discord.clear()
    }
    private func publishPresence() {
        let active = snapshot.phase == .reading && trackingEnabled
        let currentBook = snapshot.book.flatMap { current in books.first { $0.id == current.id } ?? current }
        discord.update(book: active ? currentBook : nil, progress: latestProgress?.reliable == true ? latestProgress : nil, elapsed: snapshot.sessionSeconds, enabled: discordEnabled && active, applicationID: discordApplicationID, assetKey: discordAssetKey)
        refreshDiscordStatus()
    }
    private func rememberDiscordResult() {
        let status = discord.status
        if status == "Discord activity shared" || status.contains("rejected") || status.contains("unavailable") || status.contains("connection closed") || status.contains("connection lost") {
            lastDiscordResult = status
        }
    }
    private func refreshDiscordStatus() {
        rememberDiscordResult()
        if !discordEnabled { discordStatus = "Discord sharing is off." }
        else if discordNeedsSetup { discordStatus = "Discord application ID needed." }
        else if snapshot.book?.sharingExcluded == true { discordStatus = "This book is excluded from Discord sharing." }
        else if snapshot.phase != .reading || !trackingEnabled { discordStatus = "Waiting for active reading in Books." }
        else { discordStatus = discord.status }
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
            books = archive.books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            intervals = try store.effectiveIntervals().sorted { $0.start > $1.start }
            events = archive.events.sorted { $0.date > $1.date }
            progress = archive.progress.sorted { $0.observedAt > $1.observedAt }
            merges = archive.merges
            let earliest = min(intervals.map(\.start).min() ?? Date(), Calendar.current.date(byAdding: .day, value: -365, to: Date())!)
            days = ReadingStatistics.daily(intervals: intervals, goals: archive.goals, timezoneID: timezoneID, from: earliest, through: Date())
            let key = ReadingStatistics.dayKey(Date(), timezoneID: timezoneID)
            today = days.first { $0.day == key } ?? DailyTotal(day: key, creditedSeconds: 0, uncertainSeconds: 0, manualSeconds: 0, goalMinutes: goalMinutes)
            streak = ReadingStatistics.streak(days: days, today: key)
            lastRefresh = Date()
        } catch { errorMessage = "Cannot read local history: \(error)" }
    }
    private func syncGoalFromHistory() {
        guard let archive = try? store.archive() else { return }
        let todayKey = ReadingStatistics.dayKey(Date(), timezoneID: timezoneID)
        let matching = archive.goals.enumerated().filter { $0.element.effectiveDay <= todayKey }
        if let latest = matching.max(by: { a, b in a.element.effectiveDay == b.element.effectiveDay ? a.offset < b.offset : a.element.effectiveDay < b.element.effectiveDay })?.element {
            goalMinutes = latest.minutes; savedGoal = latest.minutes; defaults.set(latest.minutes, forKey: "goalMinutes")
        }
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
        try engine.stop(); snapshot = engine.snapshot; discord.clear()
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
        guard goalMinutes.isFinite, goalMinutes >= 1, goalMinutes <= 1440, TimeZone(identifier: timezoneID) != nil, uncertaintyMinutes.isFinite, uncertaintyMinutes >= 1, uncertaintyMinutes <= 240 else { errorMessage = "Choose a goal from 1–1440 minutes, a valid timezone, and an uncertainty threshold from 1–240 minutes."; return }
        perform {
            if engine.timezoneID != timezoneID { try stopForMutation(); engine.timezoneID = timezoneID; try store.appendEvent(AuditEvent(kind: "calendarTimezoneChanged", detail: timezoneID)) }
            engine.uncertaintyThreshold = uncertaintyMinutes * 60
            if savedGoal != goalMinutes { try store.setGoal(GoalChange(effectiveDay: ReadingStatistics.dayKey(Date(), timezoneID: timezoneID), minutes: goalMinutes)); savedGoal = goalMinutes }
            defaults.set(goalMinutes, forKey: "goalMinutes"); defaults.set(timezoneID, forKey: "timezoneID"); defaults.set(uncertaintyMinutes, forKey: "uncertaintyMinutes")
            defaults.set(discordApplicationID, forKey: "discordApplicationID"); defaults.set(discordAssetKey, forKey: "discordAssetKey")
            if LoginService.enabled != launchAtLogin { try LoginService.setEnabled(launchAtLogin) }
        }
        // Show the actual registration state even if macOS rejected a change.
        launchAtLogin = LoginService.enabled
        publishPresence()
    }
    func setBookExclusions(_ book: BookRecord, tracking: Bool, sharing: Bool) {
        perform {
            var updated = book; updated.observedAt = Date(); updated.trackingExcluded = tracking; updated.sharingExcluded = sharing
            try store.saveBook(updated)
            if manualBook?.id == book.id { manualBook = updated }
            if snapshot.book?.id == book.id && book.trackingExcluded != tracking { captureGeneration += 1; try engine.stop(); snapshot = engine.snapshot; discord.clear() }
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
        perform { try stopForMutation(); if manualBook?.id == book.id { manualBook = nil }; defer { try? removeManagedBackups() }; try store.deleteBook(book.id); try resetEngineAfterMutation(); try removeUnusedCovers() }
    }
    func deleteAllData() {
        trackingEnabled = false
        perform {
            try stopForMutation(); manualBook = nil; try store.deleteAll(); try resetEngineAfterMutation(); try removeManagedBackups()
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
    func exportJSON() { guard let url = saveURL(name: "BooksPresence-history.json", type: .json) else { return }; perform { try engine.checkpoint(); try store.exportJSON(to: url) } }
    func importJSON() { guard let url = openURL(types: [.json]) else { return }; perform { try stopForMutation(); try store.importJSON(from: url); try resetEngineAfterMutation(); syncGoalFromHistory() } }
    func exportCSV() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Export tables here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        perform { try engine.checkpoint(); try store.exportCSV(to: dir.appendingPathComponent("BooksPresence-export-\(Int(Date().timeIntervalSince1970))")) }
    }
    func backup() { guard let url = saveURL(name: "BooksPresence-backup.sqlite", type: .database) else { return }; perform { try engine.checkpoint(); try store.backup(to: url) } }
    func restore() { guard let url = openURL(types: [.database, .data]) else { return }; perform { try stopForMutation(); try store.restore(from: url); try resetEngineAfterMutation(); syncGoalFromHistory() } }
    func showDashboard() { dashboardAction?() }
    func quit() { NSApp.terminate(nil) }
    func shutdown() {
        timer?.invalidate(); windowObserver?.invalidate(); captureGeneration += 1
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

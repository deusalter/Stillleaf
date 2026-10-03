# Shared interfaces

Swift 5.8, macOS 13+. No external dependencies. All app state and the core engine are used on the main thread. SQLite operations are synchronous transactions; platform captures run serially away from the main queue.

## Core (Models.swift is the authoritative value-type contract)

`public final class ReadingStore`
- `init(url: URL) throws`
- `func archive() throws -> HistoryArchive`
- `func effectiveIntervals() throws -> [ReadingInterval]`
- `func saveBook(_ book: BookRecord) throws`
- `func appendInterval(_ interval: ReadingInterval) throws`
- `func appendEvent(_ event: AuditEvent) throws`
- `func appendProgress(_ observation: ProgressObservation) throws`
- `func setGoal(_ goal: GoalChange) throws`
- `func correct(_ correction: IntervalCorrection) throws`
- `func merge(_ merge: BookMerge) throws` (append-only decisions, active false reverses source mapping)
- `func deleteSession(_ sessionID: String) throws` (actual deletion including related correction records)
- `func deleteBook(_ bookID: String) throws`
- `func deleteAll() throws`
- `func exportJSON(to url: URL) throws`
- `func importJSON(from url: URL) throws` (validate, idempotent, atomic)
- `func exportCSV(to directory: URL) throws`
- `func backup(to url: URL) throws`
- `func restore(from url: URL) throws` (validate, replace atomically; core does not delete external user backups)

`public final class TrackingEngine`
- `init(store: ReadingStore, timezoneID: String, checkpointSeconds: TimeInterval = 15) throws`
- `var snapshot: TrackerSnapshot { get }`
- `var timezoneID: String { get set }`
- `func process(_ input: TrackingInput) throws`
- `func stop(date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, reason: PauseReason = .stopped) throws`
- `func checkpoint(date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws`

Engine inputs come at most once per second and immediately on ineligibility. Credited interval fragments persist at most every 15 seconds plus transitions. Interruption gap up to 120 seconds may share the session ID but is excluded. Eligible time remains credited during long static pages. Tick gaps beyond a bounded allowance are outages, never fully credited. No downtime on recovery; record recovery without inventing the uncheckpointed tail duration. Manual mode still respects lock/sleep/pause, independent of Books foreground/access.

`public enum ReadingStatistics`
- `static func dayKey(_ date: Date, timezoneID: String) -> String`
- `static func daily(intervals: [ReadingInterval], goals: [GoalChange], timezoneID: String, from: Date, through: Date) -> [DailyTotal]`
- `static func streak(days: [DailyTotal], today: String) -> StreakSummary`

## Platform

Root owns `BooksCapture.swift`, `BooksCatalog.swift`, `CoverCache.swift`, `SystemEligibility.swift` and executable diagnostic.
`BooksCapture.capture() -> CaptureResult` reads only Books AX window metadata and controls, never prose.
`CaptureResult` contains `book: BookRecord?`, `progress: ProgressObservation?`, `pauseReason: PauseReason?`, `health: String`, `observedAt: Date`, and an ephemeral `navigationToken: String?`. Foreground, lock/display and user controls are applied by AppModel. AXDocument matched exactly to catalog path is initially the only uncalibrated automatic reader identity. Missing trustworthy reader evidence fails closed. No title-only matching.

## App view model (root owns AppModel.swift)

`@MainActor final class AppModel: ObservableObject`
Published read-only presentation fields (views can read):
- `snapshot: TrackerSnapshot`, `books: [BookRecord]`, `intervals: [ReadingInterval]`, `events: [AuditEvent]`, `progress: [ProgressObservation]`, `merges: [BookMerge]`
- `days: [DailyTotal]`, `today: DailyTotal`, `streak: StreakSummary`
- `health: String`, `lastCapture: Date?`, `errorMessage: String?`, `discordStatus: String`
Published settings with bindings: `trackingEnabled: Bool`, `discordEnabled: Bool`, `discordApplicationID: String`, `discordAssetKey: String`, `goalMinutes: Double`, `timezoneID: String`, `launchAtLogin: Bool`.
Computed `manualActive: Bool`.
Actions:
- `func startManual(title: String, author: String)` / `func startManual(book: BookRecord)` / `func stopManual()`
- `func addManual(title: String, author: String, start: Date, end: Date)`
- `func requestAccessibility()` / `func openAccessibilitySettings()`
- `func saveSettings()` (goal change effective today; register/unregister login; persist settings)
- `func setBookExclusions(_ book: BookRecord, tracking: Bool, sharing: Bool)`
- `func chooseCover(for book: BookRecord)` (file panel)
- `func editInterval(_ interval: ReadingInterval, start: Date, end: Date, bookID: String, disposition: IntervalDisposition)`
- `func splitInterval(_ interval: ReadingInterval, at: Date)`
- `func deleteSession(_ sessionID: String)` / `func deleteBook(_ book: BookRecord)` / `func deleteAllData()`
- `func mergeBooks(source: BookRecord, target: BookRecord)` / `func unmerge(_ merge: BookMerge)`
- `func exportJSON()` / `func importJSON()` / `func exportCSV()` / `func backup()` / `func restore()`
- `func showDashboard()` / `func quit()` / `func uninstall()`
- `func refresh()`

UI owns AppViews.swift and supporting *View.swift files only. Entry points: `DashboardView(model: AppModel)` and `PopoverView(model: AppModel)`.

Lifecycle/presence worker owns DiscordPresence.swift, LoginService.swift, SingleInstance.swift, packaging scripts, assets/Info.plist, and tests for Discord payloads. APIs will be assigned in a later bounded brief. Root owns package/CI, AppDelegate, AppModel and integration.

## Retained Discord activity

`ReadingPresencePolicy` keeps an in-memory last-book navigation token and monotonic activity time. `observe` accepts only fresh eligible reader captures; `state` returns hidden, reading, or paused. Background and temporarily missing reader windows retain a paused card for less than 1200 seconds since activity. The expired observation remains remembered so unchanged polling cannot resurrect the card. Explicit stops, exclusions and security/capture failures hide it. This policy never adds reading intervals. Discord `update` accepts `paused: Bool = false`; paused payloads omit timestamps.

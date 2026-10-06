import AppKit
import Combine
import SwiftUI
import BooksCore
import BooksPlatform
import CSQLite

/// Explicit developer-only self-check. Uses temporary synthetic history and an isolated defaults suite.
@MainActor
func runUISmoke() throws {
    try checkBackgroundUIPolicy()
    try checkFormSaveResults()
    try checkHistoryDateFormatting()
    try checkLibraryHistorySummary()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BooksPresence-ui-check-\(UUID().uuidString)")
    let suite = "BooksPresence.UIValidation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try checkHistoryRefreshPerformance(at: root.appendingPathComponent("performance"))
    try seedUISmokeHistory(at: root)
    let model = try AppModel(support: root, defaults: defaults, startTracking: false)
    try checkUnchangedHealthUpdates(model)
    try runSettingsDraftSmoke(model: model)
    guard let atlasSource = model.historyAtlasSource else { throw BooksAccessErrorForUI.failed("History source was not published") }
    try runHistoryAtlasNavigationSmoke(source: atlasSource)
    guard model.manualPages(forBookID: "smoke-pages-a") == 7 else {
        throw BooksAccessErrorForUI.failed("Manual page corrections were not exposed to the journal")
    }
    guard RatingSelection.value(at: -5) == 0, RatingSelection.value(at: 1) == 0.25,
          RatingSelection.value(at: 193) == 4.25, RatingSelection.value(at: 230) == 5,
          RatingSelection.value(at: 46) == 1, RatingSelection.value(at: 999) == 5 else {
        throw BooksAccessErrorForUI.failed("Quarter-star pointer selection lost boundaries or gap behavior")
    }
    model.showDashboard(section: .settings, settingsCategory: .discord)
    guard model.dashboardSectionRequest == .settings, model.settingsCategoryRequest == .discord else {
        throw BooksAccessErrorForUI.failed("Sharing setup did not route to the correct settings category")
    }
    model.dashboardSectionRequest = nil; model.settingsCategoryRequest = nil
    try checkLivePagination(model)
    try checkOnboarding(root: root.appendingPathComponent("onboarding"))
    model.discordEnabled = true
    model.discordApplicationID = ""
    model.saveSettings()
    guard model.discordNeedsSetup, model.discordStatus == "Discord application ID needed." else { throw BooksAccessErrorForUI.failed("Missing Discord setup was hidden while reading is inactive") }
    guard model.discordAssetKey.isEmpty else { throw BooksAccessErrorForUI.failed("Optional Discord artwork must not require an unconfigured asset") }
    model.discordEnabled = false
    model.saveSettings()
    // Keep this interval before the four seeded calendar days. Using "now"
    // made the self-check overlap its own 11 AM fixture at some times of day.
    _ = model.visibleReadingSessions // Warm eligibility before a history mutation.
    let end = Date().addingTimeInterval(-5 * 86_400)
    model.addManual(title: "The Shape of a Quiet Day", author: "Synthetic fixture", start: end.addingTimeInterval(-1800), end: end)
    guard let manualBook = model.books.first(where: { $0.title == "The Shape of a Quiet Day" }) else {
        throw BooksAccessErrorForUI.failed("Manual fixture was not added: \(model.errorMessage ?? "no error")")
    }
    guard model.errorMessage == nil, model.intervals.filter({ $0.bookID == manualBook.id }).count == 1,
          abs(model.intervals.filter({ $0.bookID == manualBook.id }).reduce(0) { $0 + $1.duration } - 1800) < 0.01 else {
        throw BooksAccessErrorForUI.failed("Manual addition did not produce credited history: \(model.errorMessage ?? "no error")")
    }
    guard model.visibleReadingSessions.contains(where: { $0.bookID == manualBook.id }) else {
        throw BooksAccessErrorForUI.failed("History visibility cache was not invalidated by manual addition")
    }
    let visibleIDs = model.visibleReadingSessions.map(\.id)
    let visibilityStarted = ProcessInfo.processInfo.systemUptime
    for _ in 0..<10_000 {
        guard model.visibleReadingSessions.map(\.id) == visibleIDs else {
            throw BooksAccessErrorForUI.failed("Cached History visibility changed without new evidence")
        }
    }
    print("ui-smoke: 10,000 cached History reads: \(ProcessInfo.processInfo.systemUptime - visibilityStarted) seconds")
    var originalBook = manualBook
    originalBook.observedAt = Date(timeIntervalSince1970: 0) // Deliberately stale input metadata.
    let editTime = Date()
    model.setBookExclusions(originalBook, tracking: false, sharing: true)
    guard model.books.first(where: { $0.id == manualBook.id })?.sharingExcluded == true,
          (model.books.first(where: { $0.id == manualBook.id })?.observedAt.timeIntervalSince(editTime) ?? -1) >= -0.001 else {
        throw BooksAccessErrorForUI.failed("User privacy edit was not versioned at edit time")
    }
    let interval = model.intervals.first { $0.bookID == manualBook.id }!
    model.splitInterval(interval, at: interval.start.addingTimeInterval(900))
    guard model.errorMessage == nil, model.intervals.filter({ $0.bookID == manualBook.id }).count == 2 else { throw BooksAccessErrorForUI.failed("Split failed") }
    let later = model.intervals.filter { $0.bookID == manualBook.id }.max { $0.start < $1.start }!
    model.deleteSession(later.sessionID)
    let survivingManual = model.intervals.filter { $0.bookID == manualBook.id }
    guard model.errorMessage == nil, survivingManual.count == 1, abs(survivingManual[0].duration - 900) < 0.01 else { throw BooksAccessErrorForUI.failed("Split-session deletion changed the surviving history") }

    let staging = root.appendingPathComponent("history-staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let firstHistoryBook = BookRecord(id: "smoke-finished-old", title: "The Far Shore", author: "Synthetic reader")
    let secondHistoryBook = BookRecord(id: "smoke-finished-recent", title: "The Last Chapter", author: "Synthetic reader")
    let oldDate = Date().addingTimeInterval(-14 * 86_400)
    let correctionBDate = Date().addingTimeInterval(-16 * 86_400)
    let firstRecord = CatalogFinishedBook(book: firstHistoryBook, finishedAt: oldDate, assetURL: nil)
    let intervalsBeforeHistory = model.intervals.count
    let pagesBeforeHistory = model.pages(forBookID: "smoke-pages-a")
    defaults.set(Date(), forKey: "lastAppleHistorySync")
    model.acceptFinishedHistory([firstRecord], staging: staging)
    guard model.finishedBooks.contains(where: { $0.id == firstHistoryBook.id }), model.pendingCompletion == nil,
          model.intervals.count == intervalsBeforeHistory, model.pages(forBookID: "smoke-pages-a") == pagesBeforeHistory else {
        throw BooksAccessErrorForUI.failed("Initial Apple Books history import changed reading evidence or showed an old completion as new")
    }
    let eventCountAfterFirstImport = model.events.count
    model.acceptFinishedHistory([firstRecord], staging: staging)
    guard model.events.count == eventCountAfterFirstImport else { throw BooksAccessErrorForUI.failed("Repeated Apple Books history import duplicated completion evidence") }
    let correctionBRecord = CatalogFinishedBook(book: firstHistoryBook, finishedAt: correctionBDate, assetURL: nil)
    model.acceptFinishedHistory([correctionBRecord], staging: staging)
    guard sameFixtureDate(model.finishedBooks.first(where: { $0.id == firstHistoryBook.id })?.finishedAt, correctionBDate) else {
        throw BooksAccessErrorForUI.failed("A corrected Apple Books finish date did not replace the prior imported date")
    }
    model.acceptFinishedHistory([firstRecord], staging: staging)
    guard sameFixtureDate(model.finishedBooks.first(where: { $0.id == firstHistoryBook.id })?.finishedAt, oldDate),
          model.events.filter({ $0.kind == "bookCompleted" && $0.bookID == firstHistoryBook.id }).count == 3 else {
        throw BooksAccessErrorForUI.failed("Apple Books date correction A → B → A did not retain the latest correction")
    }
    model.saveRating(4.25, for: firstHistoryBook.id)
    guard model.rating(for: firstHistoryBook.id) == 4.25 else { throw BooksAccessErrorForUI.failed("Quarter-star rating was not saved") }
    model.saveRating(0, for: firstHistoryBook.id)
    guard model.rating(for: firstHistoryBook.id) == 0 else { throw BooksAccessErrorForUI.failed("Zero-star rating was not preserved") }
    model.saveRating(nil, for: firstHistoryBook.id)
    guard model.rating(for: firstHistoryBook.id) == nil else { throw BooksAccessErrorForUI.failed("Rating clear was not preserved") }
    let savedPages = model.todayPages
    model.pageGoal = 25; model.goalMinutes = 45; model.dailyGoalUnit = .minutes; model.annualBookGoal = 18
    model.saveSettings()
    model.saveReview("A quiet, memorable ending.\n\nI would read this again.", for: firstHistoryBook.id)
    guard model.errorMessage == nil, model.todayGoal.unit == .minutes, model.todayGoal.target == 45,
          abs(model.todayGoal.value - model.today.creditedSeconds / 60) < 0.001,
          model.todayPages == savedPages else { throw BooksAccessErrorForUI.failed("Daily minutes goal changed page evidence") }
    let reopened = try AppModel(support: root, defaults: defaults, startTracking: false)
    guard reopened.dailyGoalUnit == .minutes, reopened.pageGoal == 25, reopened.goalMinutes == 45,
          reopened.annualBookGoal == 18, reopened.review(for: firstHistoryBook.id)?.contains("memorable") == true else {
        throw BooksAccessErrorForUI.failed("Goals or written review did not survive restart")
    }
    reopened.shutdown()
    model.saveReview(String(repeating: "x", count: 50_001), for: firstHistoryBook.id)
    guard model.errorMessage != nil, model.review(for: firstHistoryBook.id)?.contains("memorable") == true else {
        throw BooksAccessErrorForUI.failed("Rejected review overwrote saved text")
    }
    model.saveReview(nil, for: firstHistoryBook.id)
    guard model.review(for: firstHistoryBook.id) == nil, model.rating(for: firstHistoryBook.id) == nil else {
        throw BooksAccessErrorForUI.failed("Clearing a review changed rating semantics")
    }
    model.dailyGoalUnit = .pages; model.annualBookGoal = nil; model.saveSettings()
    guard model.todayGoal.unit == .pages, model.todayGoal.target == 25, model.goalMinutes == 45,
          model.annualBookGoal == nil, model.todayPages == savedPages else {
        throw BooksAccessErrorForUI.failed("Switching goals lost independent targets or reading evidence")
    }
    defaults.set(Date().addingTimeInterval(-3600), forKey: "lastAppleHistorySync")
    let recentRecord = CatalogFinishedBook(book: secondHistoryBook, finishedAt: Date(), assetURL: nil)
    model.acceptFinishedHistory([firstRecord, recentRecord], staging: staging)
    guard model.pendingCompletion?.id == secondHistoryBook.id,
          model.intervals.count == intervalsBeforeHistory, model.pages(forBookID: "smoke-pages-a") == pagesBeforeHistory else {
        throw BooksAccessErrorForUI.failed("Recent Apple Books completion did not remain separate from reading evidence")
    }

    if let pending = model.pendingCompletion {
        guard model.claimCompletionCelebration(for: pending), !model.claimCompletionCelebration(for: pending) else {
            throw BooksAccessErrorForUI.failed("A completion celebration replayed")
        }
    }
    model.saveReview("A private review to remove with the book.", for: firstHistoryBook.id)
    model.deleteBook(firstHistoryBook)
    model.acceptFinishedHistory([firstRecord, recentRecord], staging: staging)
    guard !model.books.contains(where: { $0.id == firstHistoryBook.id }), model.review(for: firstHistoryBook.id) == nil,
          model.intervals.count == intervalsBeforeHistory, model.pages(forBookID: "smoke-pages-a") == pagesBeforeHistory else {
        throw BooksAccessErrorForUI.failed("Deleting an imported finished book allowed a later import to resurrect it")
    }
    let beforeManualFinish = Date()
    let annualBeforeManualFinish = model.annualBooksFinished
    let completionEventsBefore = model.events.filter { $0.kind == "bookCompleted" }.count
    let evidenceBeforeFinish = model.intervals.count
    let pagesBeforeFinish = model.todayPages
    guard let marked = model.markFinished(manualBook), let markedAt = marked.finishedAt,
          markedAt >= beforeManualFinish, markedAt <= Date(), !marked.imported,
          model.annualBooksFinished == annualBeforeManualFinish + 1,
          model.intervals.count == evidenceBeforeFinish, model.todayPages == pagesBeforeFinish,
          model.rating(for: manualBook.id) == nil, model.review(for: manualBook.id) == nil,
          model.claimCompletionCelebration(for: marked), !model.claimCompletionCelebration(for: marked) else {
        throw BooksAccessErrorForUI.failed("Manual completion timestamp, yearly total or optional feedback semantics failed")
    }
    model.acknowledgeCompletion(marked)
    guard model.markFinished(manualBook)?.finishedAt == markedAt,
          model.events.filter({ $0.kind == "bookCompleted" }).count == completionEventsBefore + 1,
          model.annualBooksFinished == annualBeforeManualFinish + 1, model.pendingCompletion == nil else {
        throw BooksAccessErrorForUI.failed("Repeated manual completion duplicated a finished book or celebration")
    }
    model.acceptFinishedHistory([CatalogFinishedBook(book: manualBook, finishedAt: Date(), assetURL: nil)], staging: staging)
    guard model.pendingCompletion == nil, model.finishedBooks.first(where: { $0.id == manualBook.id })?.finishedAt == markedAt,
          model.annualBooksFinished == annualBeforeManualFinish + 1 else {
        throw BooksAccessErrorForUI.failed("Apple Books sync replayed or replaced a manual completion")
    }
    let datesEventCount = model.events.count
    let originalDates = ReadingCompletionDates(startedAt: marked.startedAt, finishedAt: marked.finishedAt)
    guard marked.startedAt == nil,
          model.saveReadingDates(originalDates, for: marked.id) == nil, model.events.count == datesEventCount else {
        throw BooksAccessErrorForUI.failed("Skipping or saving unchanged dates changed completion evidence")
    }
    let invalidDates = ReadingCompletionDates(startedAt: markedAt.addingTimeInterval(60), finishedAt: markedAt)
    guard model.saveReadingDates(invalidDates, for: marked.id) != nil, model.events.count == datesEventCount else {
        throw BooksAccessErrorForUI.failed("Invalid date draft mutated saved evidence")
    }
    let knownStart = markedAt.addingTimeInterval(-86400 * 10)
    var failureDB: OpaquePointer?
    guard sqlite3_open(root.appendingPathComponent("history.sqlite").path, &failureDB) == SQLITE_OK else {
        throw BooksAccessErrorForUI.failed("Could not open synthetic failure fixture")
    }
    defer { sqlite3_close(failureDB) }
    guard sqlite3_exec(failureDB, "CREATE TRIGGER reject_date_test BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'synthetic write failure'); END", nil, nil, nil) == SQLITE_OK else {
        throw BooksAccessErrorForUI.failed("Could not install synthetic write failure")
    }
    let failedSave = model.saveReadingDates(ReadingCompletionDates(startedAt: knownStart, finishedAt: markedAt), for: marked.id)
    guard failedSave != nil, model.events.count == datesEventCount,
          model.finishedBooks.first(where: { $0.id == marked.id })?.startedAt == nil else {
        throw BooksAccessErrorForUI.failed("Failed date save changed durable or displayed evidence")
    }
    guard sqlite3_exec(failureDB, "DROP TRIGGER reject_date_test", nil, nil, nil) == SQLITE_OK else {
        throw BooksAccessErrorForUI.failed("Could not remove synthetic failure")
    }

    guard model.saveReadingDates(ReadingCompletionDates(startedAt: knownStart, finishedAt: markedAt), for: marked.id) == nil,
          model.finishedBooks.first(where: { $0.id == marked.id })?.startedAt == knownStart,
          model.pendingCompletion == nil, !model.claimCompletionCelebration(for: marked),
          model.intervals.count == evidenceBeforeFinish, model.todayPages == pagesBeforeFinish else {
        throw BooksAccessErrorForUI.failed("Date correction changed reading activity or replayed completion")
    }
    guard model.saveReadingDates(ReadingCompletionDates(startedAt: knownStart, finishedAt: nil), for: marked.id) == nil,
          model.annualBooksFinished == annualBeforeManualFinish,
          model.finishedBooks.first(where: { $0.id == marked.id })?.finishedAt == nil,
          model.markFinished(manualBook)?.startedAt == knownStart else {
        throw BooksAccessErrorForUI.failed("Unknown finish date or repeated completion changed yearly semantics")
    }
    // Review focus 4: an undated finished book still lays out and still opens book details.
    guard let undated = model.finishedBooks.first(where: { $0.id == marked.id }), undated.finishedAt == nil else {
        throw BooksAccessErrorForUI.failed("Undated fixture was not undated")
    }
    guard case .book(let undatedBook) = FinishedBookTimeline.sheet(for: undated, books: []), undatedBook.id == undated.id,
          case .book(let knownBook) = FinishedBookTimeline.sheet(for: undated, books: model.books), knownBook.id == undated.id else {
        throw BooksAccessErrorForUI.failed("A timeline row did not open book details for its own book")
    }
    let undatedHost = NSHostingView(rootView: ReadingTimelineView(model: model))
    undatedHost.frame = NSRect(x: 0, y: 0, width: 690, height: 660)
    undatedHost.layoutSubtreeIfNeeded()
    guard model.saveReadingDates(originalDates, for: marked.id) == nil else {
        throw BooksAccessErrorForUI.failed("Could not restore synthetic reading dates")
    }
    // Themes: fallback, persistence and contrast, in an isolated defaults suite.
    let themeSuiteName = suite + ".theme"
    let themeSuite = UserDefaults(suiteName: themeSuiteName)!
    defer {
        themeSuite.removePersistentDomain(forName: themeSuiteName)
        ThemeStore.shared.reload(from: .standard)
    }
    let store = ThemeStore.shared
    themeSuite.set("bogus", forKey: ThemeStore.themeKey)
    themeSuite.set("bogus", forKey: ThemeStore.accentKey)
    themeSuite.set("bogus", forKey: ThemeStore.modeKey)
    store.reload(from: themeSuite)
    guard store.themeID == "stillleaf", store.accentID == nil else {
        throw BooksAccessErrorForUI.failed("Unknown theme or accent id did not fall back to the defaults")
    }
    guard store.appearanceMode == .system, NSApp.appearance == nil else {
        throw BooksAccessErrorForUI.failed("Unknown display mode did not follow the system")
    }
    for mode in [DashboardAppearance.light, .dark] {
        store.select(appearance: mode)
        store.reload(from: themeSuite)
        guard store.appearanceMode == mode,
              themeSuite.string(forKey: ThemeStore.modeKey) == mode.rawValue,
              NSApp.appearance?.name == mode.nativeAppearance?.name,
              store.themeID == "stillleaf", store.accentID == nil else {
            throw BooksAccessErrorForUI.failed("Display mode did not persist independently of the theme and accent")
        }
    }
    store.select(appearance: .system)
    guard NSApp.appearance == nil else { throw BooksAccessErrorForUI.failed("System mode retained a forced appearance") }
    let revisionBefore = store.revision
    store.select(theme: "ocean"); store.select(accent: "rose")
    guard store.revision > revisionBefore, themeSuite.string(forKey: ThemeStore.themeKey) == "ocean",
          themeSuite.string(forKey: ThemeStore.accentKey) == "rose",
          ThemeSnapshot.current().dark.accent == AccentPreset.named("rose")!.dark else {
        throw BooksAccessErrorForUI.failed("Theme choice did not persist or reach the palette")
    }
    store.reload(from: themeSuite)
    guard store.themeID == "ocean", store.accentID == "rose" else {
        throw BooksAccessErrorForUI.failed("Theme choice did not survive a reload")
    }
    store.select(accent: nil)
    guard themeSuite.object(forKey: ThemeStore.accentKey) == nil,
          ThemeSnapshot.current().light.accent == ReadingTheme.named("ocean").light.accent else {
        throw BooksAccessErrorForUI.failed("Clearing the accent did not restore the theme's own accent")
    }
    guard ThemeContrast.failures().isEmpty else { throw BooksAccessErrorForUI.failed("Theme contrast regressed") }
    guard SettingsCategory.allCases.contains(.appearance) else { throw BooksAccessErrorForUI.failed("Appearance settings are missing") }
    // Review focus 1: Settings (which owns unsaved drafts) and the picker being used keep their identity
    // across theme changes; other screens re-key so their colours re-resolve.
    guard DashboardView.contentKey(for: .settings, revision: 1) == DashboardView.contentKey(for: .settings, revision: 2),
          DashboardView.contentKey(for: .today, revision: 1) != DashboardView.contentKey(for: .today, revision: 2),
          SettingsView.categoryKey(for: .appearance, revision: 1) == SettingsView.categoryKey(for: .appearance, revision: 2),
          SettingsView.categoryKey(for: .reading, revision: 1) != SettingsView.categoryKey(for: .reading, revision: 2) else {
        throw BooksAccessErrorForUI.failed("Theme re-keying would reset settings drafts or the focused appearance picker")
    }
    var views: [(String, AnyView)] = [
        ("appearance", AnyView(AppearancePicker(store: store))),
        ("timeline-present", AnyView(ReadingTimelineView(model: model, present: { _ in }))),
        ("reading-dates", AnyView(ReadingDatesEditor(title: marked.title, dates: originalDates,
            timezoneID: model.timezoneID, save: { _ in "Synthetic failure; draft must stay open." }))),
        ("reading-calendar", AnyView(ReadingDateCalendar(selection: .constant(markedAt), timezoneID: model.timezoneID))),
        ("completion-sheet", AnyView(CompletionReviewSheet(model: model, entry: marked))),
        ("today", AnyView(TodayView(model: model, present: { _ in }))),
        ("library", AnyView(LibraryView(model: model, present: { _ in }))),
        ("review", AnyView(PersonalReviewsView(model: model))),
        ("timeline", AnyView(ReadingTimelineView(model: model))),
        ("reading-records", AnyView(ReadingRecordsSheet(model: model))),
        ("popover", AnyView(PopoverView(model: model))),
        ("health", AnyView(HealthView(model: model))),
        ("troubleshooting", AnyView(TrackingHelpView(model: model))),
        ("rating", AnyView(QuarterStarRating(rating: .constant(4.25)))),
        ("written-review", AnyView(BookReviewEditor(model: model, bookID: manualBook.id))),
        ("annual-goal", AnyView(AnnualReadingGoalView(model: model, openBook: { _ in }))),
        ("manual-start", AnyView(ManualStartView(model: model))),
        ("manual-add", AnyView(ManualAdditionView(model: model))),
        ("session-editor", AnyView(ReadingSessionEditor(model: model, interval: interval))),
        ("merge", AnyView(MergeBooksView(model: model, source: manualBook))),
        ("restore", AnyView(RestoreConfirmationView(model: model)))
    ]
    for scale in CalendarScale.allCases {
        views.append(("history-\(scale.rawValue)", AnyView(HistoryView(model: model, initialScale: scale))))
    }
    for category in SettingsCategory.allCases {
        views.append(("settings-\(category.rawValue)", AnyView(SettingsView(model: model, present: { _ in }, deleteAll: {}, uninstall: {}, initialCategory: category))))
    }
    if let entry = model.finishedBooks.first {
        views.append(("finished-prompt", AnyView(FinishedBookPrompt(model: model, entry: entry))))
        views.append(("finished-timeline", AnyView(FinishedBookTimeline(model: model))))
    }
    if let book = model.books.first {
        views.append(("book-detail", AnyView(BookDetailView(model: model, book: book))))
    }
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for (name, view) in views {
            let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
            hosting.frame = NSRect(x: 0, y: 0, width: name == "popover" ? 350 : 690, height: name == "popover" ? 500 : 660)
            hosting.layoutSubtreeIfNeeded()
            guard hosting.fittingSize.width.isFinite else { throw BooksAccessErrorForUI.failed("Invalid \(name) layout") }
            print("ui-smoke: \(name) \(dark ? "dark" : "light") instantiated and laid out")
        }
    }
    for theme in ReadingTheme.all {
        store.select(theme: theme.id)
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for (name, view) in [("popover", AnyView(PopoverView(model: model))), ("timeline", AnyView(ReadingTimelineView(model: model))),
                                 ("settings-appearance", AnyView(SettingsView(model: model, present: { _ in }, deleteAll: {}, uninstall: {}, initialCategory: .appearance)))] {
                let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
                hosting.frame = NSRect(x: 0, y: 0, width: name == "popover" ? 350 : 690, height: name == "popover" ? 500 : 660)
                hosting.layoutSubtreeIfNeeded()
                guard hosting.fittingSize.width.isFinite else { throw BooksAccessErrorForUI.failed("Invalid \(name) layout in \(theme.id)") }
            }
        }
    }
    let gardenDefaults = UserDefaults(suiteName: "stillleaf-garden-smoke-\(UUID().uuidString)")!
    let gardenStore = ThemeStore(defaults: gardenDefaults)
    guard gardenStore.gardenMode == .animated else { throw BooksAccessErrorForUI.failed("Garden did not default to animated") }
    gardenStore.select(garden: .off)
    guard ThemeStore(defaults: gardenDefaults).gardenMode == .off else { throw BooksAccessErrorForUI.failed("Garden mode did not persist") }
    guard gardenStore.effectiveGardenMode(reduceMotion: true) == .off else { throw BooksAccessErrorForUI.failed("Reduce Motion changed an Off garden") }
    gardenStore.select(garden: .animated)
    guard gardenStore.effectiveGardenMode(reduceMotion: true) == .still else { throw BooksAccessErrorForUI.failed("Reduce Motion did not still the garden") }
    guard gardenStore.effectiveGardenMode(reduceMotion: false) == (ProcessInfo.processInfo.isLowPowerModeEnabled ? .still : .animated) else {
        throw BooksAccessErrorForUI.failed("Low Power Mode handling is wrong")
    }
    guard GardenClock(mode: .off).frameInterval(growing: true) == nil else { throw BooksAccessErrorForUI.failed("An Off garden scheduled frames") }
    guard GardenClock(mode: .still).frameInterval(growing: false) == nil, GardenClock(mode: .still).frameInterval(growing: true) == nil else {
        throw BooksAccessErrorForUI.failed("A still garden scheduled frames")
    }
    guard GardenClock(mode: .animated).frameInterval(growing: true) == 1.0 / 30 else { throw BooksAccessErrorForUI.failed("Growth is not paced at 30 fps") }
    guard GardenClock(mode: .animated).frameInterval(growing: false) == nil else { throw BooksAccessErrorForUI.failed("A grown garden still schedules frames") }
    let gardenModel = GardenModel()
    gardenModel.configure(layout: GardenLayout(size: CGSize(width: 900, height: 620), clearingHeight: 114, seed: 3), mode: .still, now: 0)
    guard !gardenModel.field.isGrowing, gardenModel.field.cells.count > 100,
          gardenModel.field.cells.values.allSatisfy({ Double($0.y) * gardenModel.field.cellHeight >= 114 }) else {
        throw BooksAccessErrorForUI.failed("A still garden did not grow fully below the clearing")
    }
    gardenModel.configure(layout: GardenLayout(size: CGSize(width: 900, height: 620), clearingHeight: 114, seed: 3), mode: .off, now: 0)
    guard gardenModel.field.cells.isEmpty else { throw BooksAccessErrorForUI.failed("An Off garden kept cells") }
    try checkDottedProgressRow()
    var edged = GardenModel.plant(GardenLayout(size: CGSize(width: 350, height: 520), seed: 4, roots: 0, pollen: false,
                                               cornerRoots: [.bottomTrailing, .topTrailing], budget: 200, edgeBand: 2))
    edged.growToCompletion(limit: 2_000)
    guard !edged.cells.isEmpty, edged.cells.values.allSatisfy({ min($0.x, $0.y, edged.columns - 1 - $0.x, edged.rows - 1 - $0.y) < 2 }) else {
        throw BooksAccessErrorForUI.failed("An edge-band garden grew into the panel's text")
    }
    let order = VineSeedling.glyphOrder
    guard order.count > 10, order.last?.glyph == "❀", order.first.map({ $0.y == VineSeedling.art.count - 1 }) == true else {
        throw BooksAccessErrorForUI.failed("The seedling does not grow from the ground up to its bloom")
    }
    let centre = CGRect(x: 100, y: 110, width: 200, height: 80)
    let burst = VineBurst.field(size: CGSize(width: 400, height: 300), around: centre, seed: 7)
    let cellRect = { (c: VineCell) in CGRect(x: Double(c.x) * burst.cellWidth, y: Double(c.y) * burst.cellHeight, width: burst.cellWidth, height: burst.cellHeight) }
    guard burst.cells.count > 40, burst.cells.values.allSatisfy({ !cellRect($0).intersects(centre) }) else {
        throw BooksAccessErrorForUI.failed("The completion burst grew over its badge")
    }
    // Each tour step shows more of the same garden, and the last shows all of it.
    let growth = OnboardingStep.allCases.map(OnboardingView.gardenGrowth(for:))
    guard zip(growth, growth.dropFirst()).allSatisfy({ $0 < $1 }), growth.last == 1 else {
        throw BooksAccessErrorForUI.failed("The onboarding garden does not grow step by step to a full garden: \(growth)")
    }
    let tourLayout = { (step: OnboardingStep) in GardenLayout(size: OnboardingView.size, seed: 1, roots: 9, pollen: false,
        avoid: [CGRect(x: 120, y: 44, width: 540, height: 470)], vigor: 3, growth: OnboardingView.gardenGrowth(for: step)) }
    var counts: [Int] = []
    var previous: Set<Int> = []
    for step in OnboardingStep.allCases {
        var garden = GardenModel.plant(tourLayout(step))
        garden.growToCompletion(limit: 20_000)
        guard previous.isSubset(of: Set(garden.cells.keys)) else { throw BooksAccessErrorForUI.failed("Step \(step) regrew a different garden") }
        previous = Set(garden.cells.keys)
        counts.append(garden.cells.count)
    }
    guard zip(counts, counts.dropFirst()).allSatisfy({ $1 - $0 >= 40 }) else {
        throw BooksAccessErrorForUI.failed("Tour steps do not visibly grow the garden: \(counts)")
    }
    try checkGardenFollowsThemeAndNavigation()
    print("ui-smoke: garden mode defaults to animated, persists, and stills for Reduce Motion and Low Power")
    store.select(theme: "stillleaf")
    print("ui-smoke: \(ReadingTheme.all.count) themes persisted, fell back, passed contrast and laid out popover, timeline and appearance")
    let cachedBookIDs = model.books.map(\.id)
    let started = ProcessInfo.processInfo.systemUptime
    var cachedPageSum = 0
    for _ in 0..<100 {
        for bookID in cachedBookIDs {
            cachedPageSum += model.pages(forBookID: bookID)
            guard model.pages(forBookID: bookID, from: .distantPast, through: .distantFuture) == model.pages(forBookID: bookID) else {
                throw BooksAccessErrorForUI.failed("Prepared range totals differ from complete book totals")
            }
            _ = model.pagesPerMinute(forBookID: bookID)
        }
        _ = model.displayIntervals
        _ = model.readingSessions
    }
    let cachedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
    let expectedPageSum = cachedBookIDs.reduce(0) { total, bookID in
        total + PageStatistics.pages(events: model.events, effectiveIntervals: model.intervals, merges: model.merges, bookID: bookID)
    } * 100
    guard cachedPageSum == expectedPageSum else { throw BooksAccessErrorForUI.failed("Cached page totals differ from source evidence") }
    print("ui-smoke: 100 cached statistics passes: \(cachedMilliseconds) ms")
    model.deleteAllData()
    guard cachedBookIDs.allSatisfy({ model.pages(forBookID: $0) == 0 && model.pagesPerMinute(forBookID: $0) == nil }),
          cachedBookIDs.allSatisfy({ model.pages(forBookID: $0, from: .distantPast, through: .distantFuture) == 0 }),
          model.pages(from: .distantPast, through: .distantFuture) == 0,
          model.displayIntervals.isEmpty, model.readingSessions.isEmpty else {
        throw BooksAccessErrorForUI.failed("History deletion left stale cached statistics")
    }
    model.acceptFinishedHistory([firstRecord, recentRecord], staging: staging)
    guard !model.syncAppleBooksHistoryEnabled, model.books.isEmpty, model.intervals.isEmpty, model.events.isEmpty else {
        throw BooksAccessErrorForUI.failed("Deleting all data allowed Apple Books history to recreate local records")
    }
    model.shutdown()
    print("ui-smoke: model correction/deletion and native view layout checks passed (synthetic data; no screenshots)")
}

@MainActor
private func checkUnchangedHealthUpdates(_ model: AppModel) throws {
    let original = model.health
    var invalidations = 0
    let subscription = model.objectWillChange.sink { invalidations += 1 }
    defer { subscription.cancel(); model.reportHealth(original) }
    for _ in 0..<60 { model.reportHealth(original) }
    guard invalidations == 0 else {
        throw BooksAccessErrorForUI.failed("Unchanged tracker status invalidated the dashboard")
    }
    model.reportHealth("Synthetic capture unavailable")
    guard invalidations == 1, model.health == "Synthetic capture unavailable" else {
        throw BooksAccessErrorForUI.failed("A real tracker status change did not publish immediately")
    }
    for _ in 0..<60 { model.reportHealth("Synthetic capture unavailable") }
    model.reportHealth(original)
    guard invalidations == 2, model.health == original else {
        throw BooksAccessErrorForUI.failed("Repeated status or recovery published incorrectly")
    }
    print("ui-smoke: 120 identical tracker status reports emit zero dashboard invalidations; failure and recovery each publish immediately")
}

/// Uses its own history and defaults so saving the tour's goal cannot disturb the main fixture.
@MainActor
private func checkOnboarding(root: URL) throws {
    let suite = "BooksPresence.OnboardingValidation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = try AppModel(support: root, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    guard model.needsOnboarding else { throw BooksAccessErrorForUI.failed("A fresh install skipped the welcome tour") }
    var replays = 0
    model.onboardingAction = { replays += 1 }
    model.showOnboarding()
    guard replays == 1 else { throw BooksAccessErrorForUI.failed("Settings could not replay the welcome tour") }

    let savedGoals = (model.pageGoal, model.annualBookGoal)
    model.pageGoal = 5_000; model.annualBookGoal = 500
    let replay = OnboardingFlow(model: model)
    guard replay.pages == 5_000, replay.annualBooks == 500 else { throw BooksAccessErrorForUI.failed("Replaying the tour lowered goals that Settings accepts") }
    (model.pageGoal, model.annualBookGoal) = savedGoals

    let flow = OnboardingFlow(model: model)
    guard flow.step == .welcome, flow.animateReveal else { throw BooksAccessErrorForUI.failed("The tour did not start at its animated welcome") }
    flow.moveTo(.goal)
    flow.unit = .pages
    flow.setGoal(0)
    guard flow.pages == OnboardingGoalLimits.pageRange.lowerBound else { throw BooksAccessErrorForUI.failed("A page goal below one was accepted") }
    flow.setGoal(99_999)
    guard flow.pages == OnboardingGoalLimits.pageRange.upperBound else { throw BooksAccessErrorForUI.failed("An oversized page goal was accepted") }
    flow.moveTo(.tour)
    flow.moveTo(.goal)
    guard !flow.animateReveal else { throw BooksAccessErrorForUI.failed("Returning to a step replayed its entrance") }
    flow.moveTo(.appearance)
    guard flow.animateReveal else { throw BooksAccessErrorForUI.failed("A new step skipped its entrance") }
    flow.holdReveal()
    guard !flow.animateReveal else { throw BooksAccessErrorForUI.failed("A theme change would replay the step entrance") }
    guard OnboardingView.contentKey(step: .goal, revision: 1) != OnboardingView.contentKey(step: .goal, revision: 2),
          OnboardingView.contentKey(step: .goal, revision: 1) != OnboardingView.contentKey(step: .access, revision: 1) else {
        throw BooksAccessErrorForUI.failed("Onboarding content would not re-key for a step or theme change")
    }

    model.applyOnboardingGoals(unit: .minutes, pages: 25, minutes: 45, annualBooks: 18)
    guard model.errorMessage == nil, model.dailyGoalUnit == .minutes, model.goalMinutes == 45, model.pageGoal == 25,
          model.annualBookGoal == 18, model.todayGoal.unit == .minutes, model.todayGoal.target == 45 else {
        throw BooksAccessErrorForUI.failed("The tour's goal choice was not saved like a Settings change")
    }
    model.applyOnboardingGoals(unit: .pages, pages: 30, minutes: 45, annualBooks: nil)
    guard model.annualBookGoal == nil, model.todayGoal.unit == .pages, model.todayGoal.target == 30 else {
        throw BooksAccessErrorForUI.failed("Turning off the yearly goal in the tour did not clear it")
    }
    model.markOnboardingComplete()
    guard !model.needsOnboarding else { throw BooksAccessErrorForUI.failed("A finished tour would show again") }

    for granted in [false, true] {
        // Inject the reported status; this check never requests or changes OS permission.
        let stateModel = try AppModel(support: root.appendingPathComponent(granted ? "allowed" : "denied"),
            defaults: defaults, startTracking: false, accessibilityStatus: { granted })
        defer { stateModel.shutdown() }
        stateModel.refreshAccessibilityStatus()
        guard stateModel.accessibilityGranted == granted else { throw BooksAccessErrorForUI.failed("Onboarding lost its supplied permission state") }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for step in OnboardingStep.allCases {
                for expanded in step == .access ? [false, true] : [false] {
                    let view = OnboardingView(model: stateModel, flow: OnboardingFlow(model: stateModel, step: step),
                        finish: { _ in }, appleBooksSetupExpanded: expanded)
                    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
                    hosting.frame = NSRect(origin: .zero, size: OnboardingView.size)
                    hosting.layoutSubtreeIfNeeded()
                    guard hosting.fittingSize.width.isFinite, hosting.fittingSize.height.isFinite else {
                        throw BooksAccessErrorForUI.failed("Invalid onboarding \(step.title) layout (access=\(granted), expanded=\(expanded))")
                    }
                }
            }
        }
    }
    print("ui-smoke: welcome tour routed, goals saved, all steps laid out in light/dark with allowed/denied access and collapsed/expanded Apple Books setup")
}

@MainActor
private func checkLivePagination(_ model: AppModel) throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    func sample(_ page: Int, total: Int? = nil, layout: String = "large", panes: Int = 1, at seconds: Double) -> PageTurnEvidence? {
        model.observePagePosition(ReaderPagePosition(page: page, visiblePages: panes,
                                                    layoutSignature: layout, totalPages: total),
                                  bookID: "pagination-fixture", sessionID: "session",
                                  date: start.addingTimeInterval(seconds), uptime: 100 + seconds)
    }
    guard sample(72, total: 600, at: 0) == nil, model.currentPageText == "Page 72 of 600" else {
        throw BooksAccessErrorForUI.failed("Initial live pagination counted pages or lost its total")
    }
    _ = model.observePagePosition(nil, bookID: "pagination-fixture", sessionID: "session",
                                 date: start.addingTimeInterval(1), uptime: 101)
    guard sample(76, at: 2)?.pagesRead == 4, model.currentPageText == "Page 76 of 600" else {
        throw BooksAccessErrorForUI.failed("A brief missing footer discarded fast page turns or the current total")
    }
    guard sample(100, total: 1000, layout: "small", at: 3) == nil,
          model.currentPageText == "Page 100 of 1000", sample(101, layout: "small", at: 4)?.pagesRead == 1 else {
        throw BooksAccessErrorForUI.failed("Resize pagination was credited as reading or retained the old total")
    }
    _ = model.observePagePosition(nil, bookID: "pagination-fixture", sessionID: "session",
                                 date: start.addingTimeInterval(5), uptime: 105)
    guard sample(104, layout: "small", at: 11) == nil, model.currentTotalPages == nil else {
        throw BooksAccessErrorForUI.failed("A long missing-footer gap retained stale page evidence")
    }
    guard sample(105, total: 1000, layout: "small", at: 12) == nil,
          sample(106, layout: "small", at: 13)?.pagesRead == 1 else {
        throw BooksAccessErrorForUI.failed("A newly available total failed to establish a fresh pagination baseline")
    }
    _ = model.observePagePosition(nil, bookID: "pagination-fixture", sessionID: "session",
                                 date: start.addingTimeInterval(14), uptime: 114)
    var pages = 0
    for index in 0...5 {
        pages += sample(340 + index, total: index == 0 ? 600 : nil, layout: "stable-host",
                        panes: index.isMultiple(of: 2) ? 1 : 2, at: 15 + Double(index))?.pagesRead ?? 0
    }
    guard pages == 5, model.currentPageText == "Page 345 of 600" else {
        throw BooksAccessErrorForUI.failed("Chapter-container changes lost pages or the current total")
    }
}

private func seedUISmokeHistory(at root: URL) throws {
    let store = try ReadingStore(url: root.appendingPathComponent("history.sqlite"))
    let books = [BookRecord(id: "smoke-pages-a", title: "The Lantern Room", author: "Synthetic reader"),
                 BookRecord(id: "smoke-pages-b", title: "North Window", author: "Synthetic reader")]
    for book in books { try store.saveBook(book) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let today = calendar.startOfDay(for: Date())
    for offset in 0...3 {
        let date = calendar.date(byAdding: .day, value: -offset, to: today)!
        let start = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: date)!
        let interval = ReadingInterval(sessionID: "smoke-page-session-\(offset)", bookID: books[offset % books.count].id,
                                       start: start, end: start.addingTimeInterval(1_200), duration: 1_200,
                                       timezoneID: calendar.timeZone.identifier, mode: .automatic)
        try store.appendInterval(interval)
        let visiblePages = offset % 2 == 0 ? 2 : 1
        let fromPage = 30 + offset * 4
        try store.appendEvent(AuditEvent(id: "smoke-page-event-\(offset)", date: interval.end, kind: "pageTurn", bookID: interval.bookID,
                                         sessionID: interval.sessionID, detail: "Synthetic adjacent visible pages.",
                                         pageTurn: PageTurnEvidence(fromPage: fromPage, toPage: fromPage + visiblePages,
                                                                     pagesRead: visiblePages, visiblePages: visiblePages,
                                                                     layoutSignature: "smoke-\(visiblePages)-up")))
        if offset == 2 {
            try store.appendEvent(AuditEvent(id: "smoke-manual-pages", date: interval.end, kind: "manualPageAdjustment",
                                             bookID: interval.bookID, sessionID: interval.sessionID,
                                             detail: "Synthetic user correction.",
                                             pageAdjustment: ManualPageAdjustmentEvidence(pages: 7, reason: "Synthetic user correction")))
        }
    }
    try store.setGoal(GoalChange(effectiveDay: ReadingStatistics.dayKey(calendar.date(byAdding: .day, value: -7, to: today)!, timezoneID: calendar.timeZone.identifier), minutes: 20, pages: 2))
}

private func sameFixtureDate(_ lhs: Date?, _ rhs: Date, tolerance: TimeInterval = 0.001) -> Bool {
    guard let lhs else { return false }
    return abs(lhs.timeIntervalSince(rhs)) <= tolerance
}
private enum BooksAccessErrorForUI: Error { case failed(String) }

/// A synthetic library near the reported history size; never opens the user's database.
@MainActor
private func checkHistoryRefreshPerformance(at root: URL) throws {
    let suite = "BooksPresence.PerformanceValidation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ReadingStore(url: root.appendingPathComponent("history.sqlite"))
    var archive = HistoryArchive()
    archive.books = (0..<62).map { BookRecord(id: "perf-\($0)", title: "Fixture \($0)") }
    let start = Date().addingTimeInterval(-365 * 86400)
    for i in 0..<3280 {
        let date = start.addingTimeInterval(Double(i * 9000))
        let book = archive.books[i % 62].id
        let session = "session-\(i)"
        archive.intervals.append(ReadingInterval(sessionID: session, bookID: book, start: date,
            end: date.addingTimeInterval(60), duration: 60, timezoneID: "UTC", mode: .automatic))
        archive.events.append(AuditEvent(date: date.addingTimeInterval(60), kind: "pageTurn", bookID: book,
            sessionID: session, detail: "Synthetic fixture", pageTurn: PageTurnEvidence(fromPage: i + 1,
            toPage: i + 3, pagesRead: 2, visiblePages: 1, layoutSignature: "fixture")))
        if i < 1997 {
            archive.progress.append(ProgressObservation(bookID: book, observedAt: date,
                page: i + 1, totalPages: 4000, source: "fixture", reliable: true))
        }
    }
    for i in 0..<2531 {
        archive.events.append(AuditEvent(date: start.addingTimeInterval(Double(i)), kind: "bookRated",
            bookID: archive.books[i % 62].id, detail: "Synthetic rating", rating: BookRatingEvidence(value: Double(i % 11) / 2)))
    }
    let file = root.appendingPathComponent("fixture.json")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(archive).write(to: file)
    try store.importJSON(from: file)
    let model = try AppModel(support: root, defaults: defaults, startTracking: false)
    let began = ProcessInfo.processInfo.systemUptime
    for _ in 0..<10 { model.refresh() }
    guard model.errorMessage == nil, model.books.count == 62, model.events.count == 5811,
          model.intervals.count == 3280, model.progress.count == 1997 else {
        throw BooksAccessErrorForUI.failed("Synthetic performance fixture failed to refresh")
    }
    print("ui-smoke: full refresh 62 books / 5811 events / 3280 intervals / 1997 positions: \((ProcessInfo.processInfo.systemUptime - began) * 100) ms/run (10 runs)")
    let expected = LibraryProgressLabel.latestPositions(books: model.books, observations: model.progress, merges: model.merges)
    guard model.libraryProgressObservations == expected else { throw BooksAccessErrorForUI.failed("Prepared library positions changed selection") }
    // Hold a captured snapshot on the worker. Main-queue work must still execute.
    let captured = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let asyncModel = try AppModel(support: root, defaults: defaults, startTracking: false, historyReader: { url in
        let source = try ReadingStore.readSnapshot(at: url)
        captured.signal()
        guard release.wait(timeout: .now() + 10) == .success else {
            throw BooksAccessErrorForUI.failed("Worker gate timed out")
        }
        return source
    })
    let requestStart = ProcessInfo.processInfo.systemUptime
    asyncModel.requestHistoryRefresh()
    let requestMS = (ProcessInfo.processInfo.systemUptime - requestStart) * 1000
    guard captured.wait(timeout: .now() + 5) == .success else { throw BooksAccessErrorForUI.failed("Worker never read history") }
    var heartbeat = false
    DispatchQueue.main.async { heartbeat = true }
    try pumpHistoryRefresh { heartbeat }
    guard !asyncModel.historyRefreshIsIdle else { throw BooksAccessErrorForUI.failed("Slow worker did not remain gated") }
    release.signal()
    try pumpHistoryRefresh { asyncModel.historyRefreshIsIdle }
    guard asyncModel.books == model.books, asyncModel.events == model.events,
          asyncModel.todayPages == model.todayPages, asyncModel.libraryProgressObservations == expected,
          asyncModel.librarySummary == model.librarySummary else {
        throw BooksAccessErrorForUI.failed("Background presentation differs from synchronous history")
    }
    print("ui-smoke: background refresh enqueue \(requestMS) ms; main-queue heartbeat ran while snapshot worker was gated")

    // Many requests while one read is held must produce only one follow-up read.
    asyncModel.requestHistoryRefresh()
    guard captured.wait(timeout: .now() + 5) == .success else { throw BooksAccessErrorForUI.failed("Burst worker never read history") }
    for _ in 0..<20 { asyncModel.requestHistoryRefresh() }
    release.signal()
    var burstRetried = false
    try pumpHistoryRefresh {
        if !burstRetried { burstRetried = captured.wait(timeout: .now()) == .success }
        return burstRetried
    }
    release.signal()
    try pumpHistoryRefresh { asyncModel.historyRefreshIsIdle }
    guard captured.wait(timeout: .now()) == .timedOut else { throw BooksAccessErrorForUI.failed("Refresh burst was not coalesced") }
    // A burst queues just one follow-up; the older snapshot cannot overwrite an edit.
    asyncModel.requestHistoryRefresh()
    guard captured.wait(timeout: .now() + 5) == .success else { throw BooksAccessErrorForUI.failed("Second worker never read history") }
    for _ in 0..<20 { asyncModel.requestHistoryRefresh() }
    asyncModel.deleteAllData()
    guard asyncModel.books.isEmpty else { throw BooksAccessErrorForUI.failed("Delete did not publish synchronously") }
    release.signal()
    try pumpHistoryRefresh { asyncModel.historyRefreshIsIdle }
    guard asyncModel.books.isEmpty, asyncModel.events.isEmpty, asyncModel.libraryProgressObservations.isEmpty,
          asyncModel.librarySummary == LibraryHistorySummary() else {
        throw BooksAccessErrorForUI.failed("Stale worker resurrected deleted history")
    }
    // Restore while idle, then change timezone during a captured read. It must retry.
    try store.importJSON(from: file)
    asyncModel.refresh()
    asyncModel.requestHistoryRefresh()
    guard captured.wait(timeout: .now() + 5) == .success else { throw BooksAccessErrorForUI.failed("Timezone worker never read history") }
    asyncModel.timezoneID = "Pacific/Kiritimati"
    release.signal()
    var retried = false
    try pumpHistoryRefresh {
        if !retried { retried = captured.wait(timeout: .now()) == .success }
        return retried
    }
    release.signal()
    try pumpHistoryRefresh { asyncModel.historyRefreshIsIdle }
    guard asyncModel.today.day == ReadingStatistics.dayKey(Date(), timezoneID: "Pacific/Kiritimati"),
          asyncModel.books.count == 62 else { throw BooksAccessErrorForUI.failed("Timezone retry did not publish current history") }
    asyncModel.requestHistoryRefresh()
    guard captured.wait(timeout: .now() + 5) == .success else { throw BooksAccessErrorForUI.failed("Shutdown worker never read history") }
    let preShutdownEvents = asyncModel.events
    asyncModel.shutdown()
    asyncModel.requestHistoryRefresh()
    release.signal()
    try pumpHistoryRefresh { asyncModel.historyRefreshIsIdle }
    guard asyncModel.events == preShutdownEvents, captured.wait(timeout: .now()) == .timedOut else {
        throw BooksAccessErrorForUI.failed("Shutdown allowed late publication or requeue")
    }
    // Measure the main run-loop slice including publication, separately from worker latency.
    let measuredModel = try AppModel(support: root, defaults: defaults, startTracking: false)
    var longestSlice = 0.0
    let backgroundStart = ProcessInfo.processInfo.systemUptime
    for _ in 0..<10 {
        measuredModel.requestHistoryRefresh()
        let deadline = Date().addingTimeInterval(10)
        while !measuredModel.historyRefreshIsIdle, Date() < deadline {
            let sliceStart = ProcessInfo.processInfo.systemUptime
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            longestSlice = max(longestSlice, ProcessInfo.processInfo.systemUptime - sliceStart)
        }
        guard measuredModel.historyRefreshIsIdle else { throw BooksAccessErrorForUI.failed("Measured refresh timed out") }
    }
    print("ui-smoke: background end-to-end refresh \((ProcessInfo.processInfo.systemUptime - backgroundStart) * 100) ms/run (10 runs)")
    print("ui-smoke: maximum main run-loop slice during 10 background refreshes \(longestSlice * 1000) ms (includes publication; not a frame-rate measurement)")
    let source = archive.intervals[0]
    let writeStart = ProcessInfo.processInfo.systemUptime
    for _ in 0..<20 {
        try store.appendEvent(AuditEvent(date: source.end, kind: "pageTurn", bookID: source.bookID,
            sessionID: source.sessionID, detail: "Synthetic validation timing",
            pageTurn: PageTurnEvidence(fromPage: 1, toPage: 2, pagesRead: 1, visiblePages: 1, layoutSignature: "fixture")))
    }
    print("ui-smoke: durable page event validation/write \((ProcessInfo.processInfo.systemUptime - writeStart) * 50) ms/run (20 runs)")
    // Prove a warm cache is replaced on refresh, including source deletions.
    model.deleteAllData()
    model.refresh()
    guard model.libraryProgressObservations.isEmpty, model.rating(for: "perf-0") == nil else {
        throw BooksAccessErrorForUI.failed("Refresh retained deleted rating or position evidence")
    }
}

@MainActor
private func pumpHistoryRefresh(until finished: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(10)
    while !finished(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }
    guard finished() else { throw BooksAccessErrorForUI.failed("Background refresh timed out") }
}

@MainActor
private func checkHistoryDateFormatting() throws {
    let parser = ISO8601DateFormatter()
    let dates = ["2026-03-08T09:59:00Z", "2026-03-08T10:01:00Z",
                 "2026-11-01T08:59:00Z", "2026-11-01T09:01:00Z"].map { parser.date(from: $0)! }
    let zones = ["America/Los_Angeles", "Europe/London", "Asia/Kathmandu", "UTC", "Invalid/Zone"]
    let patterns = ["EEEE, MMMM d, yyyy", "MMM", "MMMM yyyy", "ha", "h:mm a z",
                    "EEE", "EEEE, MMMM d", "MMMM", "EEEE d"]
    // More than 32 zone/pattern pairs exercise bounded eviction. Revisit them
    // in reverse order, and alternate DST dates through each warmed formatter.
    for orderedZones in [zones, Array(zones.reversed())] {
        for zone in orderedZones {
            for pattern in patterns {
                let reference = DateFormatter(); reference.locale = .current
                reference.timeZone = TimeZone(identifier: zone) ?? .current
                reference.dateFormat = pattern
                for date in dates + Array(dates.reversed()) {
                    guard DateText.string(date, zone: zone, pattern: pattern) == reference.string(from: date) else {
                        throw BooksAccessErrorForUI.failed("History date formatting changed for \(zone), \(pattern), \(date)")
                    }
                }
            }
        }
    }
    print("ui-smoke: History date labels preserve timezone, DST, patterns and cache eviction")
}


/// The dotted progress row fills from the leading edge in the accent colour.
@MainActor
private func checkDottedProgressRow() throws {
    NSApp.appearance = NSAppearance(named: .aqua)
    let accent = ThemeSnapshot.current().light.accent
    let hosting = NSHostingView(rootView: DottedProgressRow(fraction: 0.38).frame(width: 360, height: 12)
        .environment(\.colorScheme, .light))
    hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 12)
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw BooksAccessErrorForUI.failed("Could not render the dotted row") }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    func accentPixels(_ range: Range<Int>) -> Int {
        var count = 0
        for x in range { for y in 0..<bitmap.pixelsHigh {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
            let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255), b = Int(c.blueComponent * 255)
            if abs(r - Int((accent >> 16) & 0xff)) + abs(g - Int((accent >> 8) & 0xff)) + abs(b - Int(accent & 0xff)) < 60 { count += 1 }
        } }
        return count
    }
    let third = bitmap.pixelsWide / 3
    guard accentPixels(0..<third) > 20, accentPixels((2 * third)..<bitmap.pixelsWide) == 0 else {
        throw BooksAccessErrorForUI.failed("The dotted progress row does not fill from the leading edge")
    }
    print("ui-smoke: dotted progress row fills 38% from the leading edge")
}


/// The garden recolours when the theme changes, keeps its growth across a
/// History clearing change, and the menu panel's vines stay in their gutters.
@MainActor
private func checkGardenFollowsThemeAndNavigation() throws {
    let previousFrozen = GardenClock.frozenTime
    GardenClock.frozenTime = 6
    defer { GardenClock.frozenTime = previousFrozen; ThemeStore.shared.select(accent: nil) }
    NSApp.appearance = NSAppearance(named: .aqua)
    ThemeStore.shared.select(accent: nil)
    let size = NSSize(width: 600, height: 400)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    let controller = NSHostingController(rootView: GardenCanvas(layout: GardenLayout(seed: 11, pollen: false), mode: .animated)
        .frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
    controller.sizingOptions = []
    window.contentViewController = controller
    window.setContentSize(size)
    let hosting = controller.view
    hosting.frame = NSRect(origin: .zero, size: size)
    defer { window.contentViewController = nil; window.close() }
    func snapshot() -> NSBitmapImageRep? {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
    func inked(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) { for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            if let c = bitmap.colorAt(x: x, y: y), c.alphaComponent > 0.3 { count += 1 }
        } }
        return count
    }
    guard let before = snapshot(), inked(before) > 50 else { throw BooksAccessErrorForUI.failed("The garden drew nothing to compare") }
    ThemeStore.shared.select(accent: "rose")
    guard let after = snapshot(), before.tiffRepresentation != after.tiffRepresentation else {
        throw BooksAccessErrorForUI.failed("The garden did not recolour when the accent changed")
    }

    let model = GardenModel()
    let today = GardenLayout(size: CGSize(width: 900, height: 620), clearingHeight: 166, seed: 5)
    model.configure(layout: today, mode: .still, now: 0)
    let generation = model.generation, cells = model.field.cells.count
    var history = today
    history.clearingHeight = 250
    model.configure(layout: history, mode: .still, now: 1)
    guard model.generation == generation, model.field.cells.count == cells else {
        throw BooksAccessErrorForUI.failed("Visiting History regrew the garden from scratch")
    }

    // The menu panel's garden: a trellis confined to the top and bottom bands, plus a vine up each side,
    // on every day's seed. Cards fill the middle, so nothing may grow there, and the garden must be real.
    var blooms = 0
    for dayIndex in 0..<60 {
        let day = String(format: "2026-%02d-%02d", 1 + dayIndex / 28, 1 + dayIndex % 28)
        var trellisLayout = MenuPanelGarden.trellis(day: day)
        trellisLayout.size = CGSize(width: 350, height: 560)
        var trellis = GardenModel.plant(trellisLayout)
        trellis.growToCompletion(limit: 4_000)
        let band = MenuPanelGarden.trellisBand
        guard trellis.cells.values.allSatisfy({ $0.y < band || $0.y >= trellis.rows - band }) else {
            throw BooksAccessErrorForUI.failed("The menu panel trellis grew into the card area on \(day)")
        }
        guard trellis.cells.count >= 60 else {
            throw BooksAccessErrorForUI.failed("The menu panel trellis is too sparse on \(day): \(trellis.cells.count) cells")
        }
        blooms += trellis.cells.values.filter { $0.kind == .bloom }.count
        for side in [MenuPanelGarden.Side.leading, .trailing] {
            var layout = MenuPanelGarden.side(side, day: day)
            layout.size = CGSize(width: MenuPanelGarden.sideWidth, height: 560 - 2 * CGFloat(band) * CGFloat(GardenModel.cellHeight))
            var vine = GardenModel.plant(layout)
            vine.growToCompletion(limit: 4_000)
            guard vine.cells.count >= 20, vine.cells.values.map(\.y).max()! - vine.cells.values.map(\.y).min()! > vine.rows / 2 else {
                throw BooksAccessErrorForUI.failed("The menu panel \(side) vine does not climb the side on \(day)")
            }
            blooms += vine.cells.values.filter { $0.kind == .bloom }.count
        }
    }
    guard blooms > 0 else { throw BooksAccessErrorForUI.failed("The menu panel garden never blooms") }
    print("ui-smoke: garden recolours with the theme, survives History's clearing, and grows the menu panel trellis and side vines in their gutters")
}

/// Dev-tool launches stay out of the way unless asked to come forward or running on CI.
@MainActor
private func checkBackgroundUIPolicy() throws {
    func enabled(_ arguments: [String], _ environment: [String: String] = [:]) -> Bool {
        BackgroundUI.shouldEnable(arguments: ["BooksPresence"] + arguments, environment: environment)
    }
    guard enabled(["--self-test-epub", "book.epub"]), enabled(["--preview-library"]), enabled(["--render-native-chrome", "out"]),
          !enabled([]), !enabled(["--preview-library"], ["CI": "true"]), !enabled(["--self-test-ui"], ["STILLLEAF_FOREGROUND_UI": "1"]) else {
        throw BooksAccessErrorForUI.failed("background UI policy: dev-tool launches must run in the background except on CI or when asked to come forward, and the app itself never does")
    }
}

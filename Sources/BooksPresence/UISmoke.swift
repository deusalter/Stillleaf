import AppKit
import SwiftUI
import BooksCore
import BooksPlatform

/// Explicit developer-only self-check. Uses temporary synthetic history and an isolated defaults suite.
@MainActor
func runUISmoke() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BooksPresence-ui-check-\(UUID().uuidString)")
    let suite = "BooksPresence.UIValidation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try seedUISmokeHistory(at: root)
    let model = try AppModel(support: root, defaults: defaults, startTracking: false)
    model.discordEnabled = true
    model.discordApplicationID = ""
    model.saveSettings()
    guard model.discordNeedsSetup, model.discordStatus == "Discord application ID needed." else { throw BooksAccessErrorForUI.failed("Missing Discord setup was hidden while reading is inactive") }
    guard model.discordAssetKey.isEmpty else { throw BooksAccessErrorForUI.failed("Optional Discord artwork must not require an unconfigured asset") }
    model.discordEnabled = false
    model.saveSettings()
    let end = Date().addingTimeInterval(-120)
    model.addManual(title: "The Shape of a Quiet Day", author: "Synthetic fixture", start: end.addingTimeInterval(-1800), end: end)
    let manualBook = model.books.first { $0.title == "The Shape of a Quiet Day" }!
    guard model.errorMessage == nil, model.intervals.filter({ $0.bookID == manualBook.id }).count == 1,
          abs(model.intervals.filter({ $0.bookID == manualBook.id }).reduce(0) { $0 + $1.duration } - 1800) < 0.01 else {
        throw BooksAccessErrorForUI.failed("Manual addition did not produce credited history: \(model.errorMessage ?? "no error")")
    }
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
    defaults.set(Date().addingTimeInterval(-3600), forKey: "lastAppleHistorySync")
    let recentRecord = CatalogFinishedBook(book: secondHistoryBook, finishedAt: Date(), assetURL: nil)
    model.acceptFinishedHistory([firstRecord, recentRecord], staging: staging)
    guard model.pendingCompletion?.id == secondHistoryBook.id,
          model.intervals.count == intervalsBeforeHistory, model.pages(forBookID: "smoke-pages-a") == pagesBeforeHistory else {
        throw BooksAccessErrorForUI.failed("Recent Apple Books completion did not remain separate from reading evidence")
    }

    model.deleteBook(firstHistoryBook)
    model.acceptFinishedHistory([firstRecord, recentRecord], staging: staging)
    guard !model.books.contains(where: { $0.id == firstHistoryBook.id }),
          model.intervals.count == intervalsBeforeHistory, model.pages(forBookID: "smoke-pages-a") == pagesBeforeHistory else {
        throw BooksAccessErrorForUI.failed("Deleting an imported finished book allowed a later import to resurrect it")
    }
    var views: [(String, AnyView)] = [
        ("today", AnyView(TodayView(model: model, present: { _ in }))),
        ("library", AnyView(LibraryView(model: model, present: { _ in }))),
        ("review", AnyView(ReviewView(model: model, present: { _ in }))),
        ("popover", AnyView(PopoverView(model: model)))
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
    model.deleteAllData()
    model.acceptFinishedHistory([firstRecord, recentRecord], staging: staging)
    guard !model.syncAppleBooksHistoryEnabled, model.books.isEmpty, model.intervals.isEmpty, model.events.isEmpty else {
        throw BooksAccessErrorForUI.failed("Deleting all data allowed Apple Books history to recreate local records")
    }
    model.shutdown()
    print("ui-smoke: model correction/deletion and native view layout checks passed (synthetic data; no screenshots)")
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
    }
    try store.setGoal(GoalChange(effectiveDay: ReadingStatistics.dayKey(calendar.date(byAdding: .day, value: -7, to: today)!, timezoneID: calendar.timeZone.identifier), minutes: 20, pages: 2))
}

private func sameFixtureDate(_ lhs: Date?, _ rhs: Date, tolerance: TimeInterval = 0.001) -> Bool {
    guard let lhs else { return false }
    return abs(lhs.timeIntervalSince(rhs)) <= tolerance
}
private enum BooksAccessErrorForUI: Error { case failed(String) }

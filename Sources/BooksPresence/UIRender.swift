import AppKit
import SwiftUI
import BooksCore

/// Renders only app-owned views with synthetic history; never captures the screen or the user's database.
@MainActor
func renderUIPreviews(to destination: URL) throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("BooksPresence-preview-\(UUID().uuidString)")
    let suite = "BooksPresence.Preview.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set("America/Los_Angeles", forKey: "timezoneID")
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: support)
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try seedPreviewHistory(at: support)
    let model = try AppModel(support: support, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    for dark in [true, false] {
        let scheme: ColorScheme = dark ? .dark : .light
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        var previews: [(String, AnyView)] = []
        for scale in CalendarScale.allCases {
            previews.append(("history-\(scale.rawValue)", AnyView(DashboardView(model: model, initialSection: .history, initialCalendarScale: scale))))
        }
        for category in SettingsCategory.allCases {
            previews.append(("settings-\(category.rawValue.lowercased())", AnyView(DashboardView(model: model, initialSection: .settings, initialSettingsCategory: category))))
        }
        for section in [DashboardSection.today, .library] {
            previews.append((section.rawValue, AnyView(DashboardView(model: model, initialSection: section))))
        }
        if let entry = model.finishedBooks.first {
            previews.append(("finished-prompt", AnyView(FinishedBookPrompt(model: model, entry: entry))))
            previews.append(("finished-timeline", AnyView(ScrollView { FinishedBookTimeline(model: model).padding(24) }.background(ReadingPalette.paper))))
        }
        if let book = model.books.first {
            previews.append(("book-detail", AnyView(BookDetailView(model: model, book: book))))
        }
        for (name, view) in previews {
            let view = view.environment(\.colorScheme, scheme)
            try renderNativeView(AnyView(view), size: NSSize(width: 1180, height: 820), appearance: appearance,
                                 to: destination.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
        let compact = DashboardView(model: model, initialSection: .history).environment(\.colorScheme, scheme)
        try renderNativeView(AnyView(compact), size: NSSize(width: 920, height: 660), appearance: appearance,
                             to: destination.appendingPathComponent("history-compact-\(dark ? "dark" : "light").png"))
    }
    print("ui-render: synthetic light/dark native previews saved to \(destination.path)")
}

@MainActor
private func renderNativeView(_ view: AnyView, size: NSSize, appearance: NSAppearance?, to output: URL) throws {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = appearance
    window.contentView = hosting
    window.orderBack(nil)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    hosting.displayIfNeeded()
    defer { window.close() }
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw UIPreviewError.renderFailed
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw UIPreviewError.renderFailed }
    try data.write(to: output, options: .atomic)
}

private func seedPreviewHistory(at support: URL) throws {
    let store = try ReadingStore(url: support.appendingPathComponent("history.sqlite"))
    let books = [BookRecord(id: "preview-waves", title: "The Waves", author: "Virginia Woolf"),
                 BookRecord(id: "preview-walden", title: "Walden", author: "Henry David Thoreau"),
                 BookRecord(id: "preview-rooms", title: "A Room of One’s Own", author: "Virginia Woolf")]
    for book in books { try store.saveBook(book) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let today = calendar.startOfDay(for: Date())
    for offset in 1...65 where offset % 5 != 0 {
        let date = calendar.date(byAdding: .day, value: -offset, to: today)!
        let start = calendar.date(bySettingHour: 19, minute: offset % 3 * 10, second: 0, of: date)!
        let duration = Double(12 + (offset * 13) % 48) * 60
        let book = books[offset % books.count]
        let mode: ReadingMode = offset % 4 == 0 ? .manual : .automatic
        let disposition: IntervalDisposition = offset % 13 == 0 ? .uncertain : .credited
        let interval = ReadingInterval(sessionID: "preview-session-\(offset)", bookID: book.id,
                                       start: start, end: start.addingTimeInterval(duration), duration: duration,
                                       timezoneID: calendar.timeZone.identifier, mode: mode, disposition: disposition)
        try store.appendInterval(interval)
        if mode == .automatic, disposition == .credited {
            let visiblePages = offset % 3 == 0 ? 2 : 1
            let fromPage = 20 + offset * 3
            try store.appendEvent(AuditEvent(id: "preview-page-\(offset)", date: interval.end, kind: "pageTurn", bookID: book.id,
                                             sessionID: interval.sessionID, detail: "Synthetic adjacent visible pages.",
                                             pageTurn: PageTurnEvidence(fromPage: fromPage, toPage: fromPage + visiblePages,
                                                                         pagesRead: visiblePages, visiblePages: visiblePages,
                                                                         layoutSignature: "preview-\(visiblePages)-up")))
        }
    }
    let end = Date().addingTimeInterval(-60)
    let start = max(today, end.addingTimeInterval(-1680))
    if end > start {
        try store.appendInterval(ReadingInterval(sessionID: "preview-today", bookID: books[0].id,
                                                start: start, end: end, duration: end.timeIntervalSince(start),
                                                timezoneID: calendar.timeZone.identifier, mode: .manual))
    }
    let earlierEnd = end.addingTimeInterval(-1800)
    let earlierStart = max(today, earlierEnd.addingTimeInterval(-900))
    if earlierEnd > earlierStart {
        let interval = ReadingInterval(sessionID: "preview-today-earlier", bookID: books[1].id,
                                       start: earlierStart, end: earlierEnd, duration: earlierEnd.timeIntervalSince(earlierStart),
                                       timezoneID: calendar.timeZone.identifier, mode: .automatic)
        try store.appendInterval(interval)
        try store.appendEvent(AuditEvent(id: "preview-page-today", date: interval.end, kind: "pageTurn", bookID: books[1].id,
                                         sessionID: interval.sessionID, detail: "Synthetic adjacent visible pages.",
                                         pageTurn: PageTurnEvidence(fromPage: 40, toPage: 42, pagesRead: 2, visiblePages: 2,
                                                                     layoutSignature: "preview-2-up")))
    }
    try store.setGoal(GoalChange(effectiveDay: ReadingStatistics.dayKey(calendar.date(byAdding: .day, value: -90, to: today)!, timezoneID: calendar.timeZone.identifier), minutes: 20, pages: 8))
    try store.appendEvent(AuditEvent(id: "preview-finished-waves", date: today.addingTimeInterval(-3 * 86_400), kind: "bookCompleted", bookID: books[0].id,
                                     detail: "Synthetic Apple Books completion metadata.",
                                     completion: BookCompletionEvidence(finishedAt: today.addingTimeInterval(-3 * 86_400), source: "Apple Books", imported: true)))
    try store.appendEvent(AuditEvent(id: "preview-rating-waves", date: today.addingTimeInterval(-3 * 86_400 + 10), kind: "bookRated", bookID: books[0].id,
                                     detail: "Synthetic reader rating.", rating: BookRatingEvidence(value: 4.25)))
    try store.appendEvent(AuditEvent(id: "preview-finished-walden", date: today.addingTimeInterval(-86_400), kind: "bookCompleted", bookID: books[1].id,
                                     detail: "Synthetic Apple Books completion metadata.",
                                     completion: BookCompletionEvidence(finishedAt: today.addingTimeInterval(-86_400), source: "Apple Books", imported: true)))
    try store.appendEvent(AuditEvent(id: "preview-rating-walden", date: today.addingTimeInterval(-86_400 + 10), kind: "bookRated", bookID: books[1].id,
                                     detail: "Synthetic reader rating.", rating: BookRatingEvidence(value: 0)))
}

private enum UIPreviewError: Error { case renderFailed }

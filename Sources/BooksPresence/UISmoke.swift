import AppKit
import SwiftUI
import BooksCore

/// Explicit developer-only self-check. Uses temporary synthetic history and an isolated defaults suite.
@MainActor
func runUISmoke() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BooksPresence-ui-check-\(UUID().uuidString)")
    let suite = "BooksPresence.UIValidation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    let model = try AppModel(support: root, defaults: defaults, startTracking: false)
    let end = Date().addingTimeInterval(-120)
    model.addManual(title: "The Shape of a Quiet Day", author: "Synthetic fixture", start: end.addingTimeInterval(-1800), end: end)
    guard model.errorMessage == nil, model.intervals.count == 1, abs(model.intervals.reduce(0) { $0 + $1.duration } - 1800) < 0.01 else { throw BooksAccessErrorForUI.failed("Manual addition did not produce credited history: \(model.errorMessage ?? "no error")") }
    var originalBook = model.books[0]
    originalBook.observedAt = Date(timeIntervalSince1970: 0) // Deliberately stale input metadata.
    let editTime = Date()
    model.setBookExclusions(originalBook, tracking: false, sharing: true)
    guard model.books[0].sharingExcluded, model.books[0].observedAt.timeIntervalSince(editTime) >= -0.001 else { throw BooksAccessErrorForUI.failed("User privacy edit was not versioned at edit time") }
    let interval = model.intervals[0]
    model.splitInterval(interval, at: interval.start.addingTimeInterval(900))
    guard model.errorMessage == nil, model.intervals.count == 2 else { throw BooksAccessErrorForUI.failed("Split failed") }
    let later = model.intervals.max { $0.start < $1.start }!
    model.deleteSession(later.sessionID)
    guard model.errorMessage == nil, model.intervals.count == 1, abs(model.intervals[0].duration - 900) < 0.01 else { throw BooksAccessErrorForUI.failed("Split-session deletion changed the surviving history") }
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
    model.shutdown()
    print("ui-smoke: model correction/deletion and native view layout checks passed (synthetic data; no screenshots)")
}
private enum BooksAccessErrorForUI: Error { case failed(String) }

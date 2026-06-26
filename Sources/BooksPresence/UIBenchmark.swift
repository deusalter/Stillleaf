import AppKit
import SwiftUI
import BooksCore

/// Measures synchronous destination construction and layout, excluding fixture setup,
/// disk writes and arbitrary animation waits. Never reads the user's history.
@MainActor
func runUIBenchmark() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-benchmark-\(UUID().uuidString)")
    let suite = "Stillleaf.Benchmark.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set("America/Los_Angeles", forKey: "timezoneID")
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var archive = HistoryArchive()
    archive.books = (0..<60).map { BookRecord(id: "book-\($0)", title: "Synthetic Book \($0)") }
    let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600)
    for index in 0..<2000 {
        let start = end.addingTimeInterval(Double(index - 2000) * 1800)
        let book = archive.books[index % archive.books.count]
        let session = "session-\(index / 10)"
        archive.intervals.append(ReadingInterval(sessionID: session, bookID: book.id, start: start,
            end: start.addingTimeInterval(600), duration: 600, timezoneID: "America/Los_Angeles", mode: .automatic))
        let turn = 1
        archive.events.append(AuditEvent(date: start.addingTimeInterval(600), kind: "pageTurn",
                bookID: book.id, sessionID: session, detail: "Synthetic performance fixture",
                pageTurn: PageTurnEvidence(fromPage: turn, toPage: turn + 3, pagesRead: 3, visiblePages: 1, layoutSignature: "fixture")))
    }
    let fixture = root.appendingPathComponent("fixture.json")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(archive).write(to: fixture)
    let store = try ReadingStore(url: root.appendingPathComponent("history.sqlite"))
    try store.importJSON(from: fixture)
    let model = try AppModel(support: root, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(rootView: AnyView(Text("Ready")))
    window.contentView = hosting; window.orderBack(nil)
    defer { window.close() }
    print("ui-benchmark: 60 books, 2000 intervals, 2000 page events; synchronous destination layout (ms)")
    for pass in 0..<3 {
        for target in ["month", "year", "week", "day", "library", "today", "settings", "review", "health"] {
            hosting.rootView = AnyView(Text("Ready")); hosting.layoutSubtreeIfNeeded()
            let start = ProcessInfo.processInfo.systemUptime
            if let scale = CalendarScale(rawValue: target) {
                hosting.rootView = AnyView(HistoryView(model: model, initialScale: scale))
            } else {
                let section: DashboardSection = target == "library" ? .library : target == "today" ? .today : target == "review" ? .review : target == "health" ? .health : .settings
                hosting.rootView = AnyView(DashboardView(model: model, initialSection: section))
            }
            hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            print("ui-benchmark: pass \(pass + 1) \(target): \(String(format: "%.2f", elapsed))")
        }
    }
}

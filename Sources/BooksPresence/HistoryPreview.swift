import AppKit
import SwiftUI
import BooksCore

/// Isolated, synthetic fixtures: this path never starts tracking or opens the live store.
@MainActor
func renderHistoryJournalPreviews(to destination: URL) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("History-preview-\(UUID().uuidString)")
    let suite = "History.Preview.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let timezone = "America/Los_Angeles"
    defaults.set(timezone, forKey: "timezoneID")
    ThemeStore.shared.reload(from: defaults)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        ThemeStore.shared.reload(from: .standard)
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timezone)!
    let day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
    let titles = ["The Waves", "A Room of One’s Own", "The Book of the New Sun: The Shadow of the Torturer", "Walden", "The Sea and the Mirror", "The Secret Garden"]
    for fixture in ["day", "dense", "sparse", "empty", "review"] {
        let support = root.appendingPathComponent(fixture)
        let store = try ReadingStore(url: support.appendingPathComponent("history.sqlite"))
        let count = fixture == "empty" ? 0 : fixture == "dense" ? 6 : fixture == "day" ? 2 : 1
        for index in 0..<count {
            let book = BookRecord(id: "history-\(index)", title: titles[index], author: index == 0 || index == 1 ? "Virginia Woolf" : "A reader’s library")
            try store.saveBook(book)
            for visit in 0..<(fixture == "dense" ? 3 : 1) {
                let start = day.addingTimeInterval(Double(8 + index * 2) * 3600 + Double(visit * 1800))
                let hasPages = fixture != "sparse" && fixture != "review"
                let fragments = hasPages ? 12 : 1
                let duration = 1200.0 / Double(fragments)
                for fragment in 0..<fragments {
                    let fragmentStart = start.addingTimeInterval(Double(fragment) * duration)
                    let interval = ReadingInterval(sessionID: "\(fixture)-\(index)-\(visit)", bookID: book.id,
                        start: fragmentStart, end: fragmentStart.addingTimeInterval(duration), duration: duration,
                        timezoneID: timezone, mode: hasPages ? .automatic : .manual,
                        disposition: fixture == "review" ? .uncertain : .credited)
                    try store.appendInterval(interval)
                    if hasPages {
                        let page = 20 + visit * 12 + fragment
                        try store.appendEvent(AuditEvent(date: interval.end, kind: "pageTurn", bookID: book.id,
                            sessionID: interval.sessionID, detail: "Synthetic History preview",
                            pageTurn: PageTurnEvidence(fromPage: page, toPage: page + 1, pagesRead: 1,
                                visiblePages: 1, layoutSignature: "preview")))
                    }
                }
            }
        }
        let model = try AppModel(support: support, defaults: defaults, startTracking: false)
        defer { model.shutdown() }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            let scales: [CalendarScale] = fixture == "day" ? [.day, .week, .month, .year] : [.day]
            for scale in scales {
              for width in fixture == "day" && scale == .day ? [920, 680] : [920] {
                let view = HistoryView(model: model, initialScale: scale, anchor: day)
                    .frame(width: CGFloat(width), height: fixture == "dense" ? 1800 : width == 680 ? 660 : 820)
                    .background(ReadingPalette.canvas).foregroundStyle(ReadingPalette.ink)
                    .tint(ReadingPalette.accent).environment(\.colorScheme, dark ? .dark : .light)
                let size = NSSize(width: CGFloat(width), height: fixture == "dense" ? 1800 : width == 680 ? 660 : 820)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                let host = NSHostingView(rootView: view)
                host.appearance = appearance
                window.contentView = host
                window.orderBack(nil)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                defer { window.contentView = nil; window.close() }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw HistoryPreviewError.renderFailed }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw HistoryPreviewError.renderFailed }
                let name = (fixture == "day" ? scale.rawValue : fixture) + (width == 680 ? "-compact" : "")
                try data.write(to: destination.appendingPathComponent("history-\(name)-\(dark ? "dark" : "light").png"))
              }
            }
        }
    }
    print("History previews saved to \(destination.path)")
}

private enum HistoryPreviewError: Error { case renderFailed }

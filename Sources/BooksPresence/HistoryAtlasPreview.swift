import AppKit
import SwiftUI
import BooksCore

/// Developer-only native rendering with isolated stores. Never starts tracking or playback.
@MainActor
func renderHistoryAtlasPreviews(to destination: URL) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Atlas-preview-\(UUID().uuidString)")
    let suite = "Atlas.Preview.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set("America/Los_Angeles", forKey: "timezoneID")
    ThemeStore.shared.reload(from: defaults)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root); ThemeStore.shared.reload(from: .standard) }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
    for fixture in ["standard", "dense", "sparse", "empty", "review", "merged"] {
        let support = root.appendingPathComponent(fixture)
        let store = try ReadingStore(url: support.appendingPathComponent("history.sqlite"))
        let titles = ["The Remains of the Day", "The Summer Book", "The Left Hand of Darkness", "Invisible Cities", "The Sea, the Sea", "A Room of One’s Own", "The Waves", "Piranesi", "The Book of the New Sun: The Shadow of the Torturer", "Middlemarch", "The Odyssey", "The Secret Garden"]
        let authors = ["Kazuo Ishiguro", "Tove Jansson", "Ursula K. Le Guin", "Italo Calvino", "Iris Murdoch", "Virginia Woolf", "Virginia Woolf", "Susanna Clarke", "Gene Wolfe", "George Eliot", "Homer", "Frances Hodgson Burnett"]
        let count = fixture == "dense" ? 12 : fixture == "empty" ? 0 : fixture == "standard" ? 8 : 1
        let books = (0..<count).map { index in BookRecord(id: "atlas-\(index)", title: titles[index], author: authors[index], format: [1, 7].contains(index) ? .audiobook : .text) }
        for book in books { try store.saveBook(book) }
        func record(_ book: BookRecord, date: Date, hour: Int, minutes: Int, pages: Int, disposition: IntervalDisposition = .credited, suffix: String) throws {
            let start = calendar.date(bySettingHour: hour, minute: 10, second: 0, of: date)!
            let session = "\(book.id)-\(suffix)", fragments = max(1, pages), seconds = Double(minutes * 60) / Double(fragments)
            for offset in 0..<fragments {
                let instant = start.addingTimeInterval(Double(offset) * seconds)
                let interval = ReadingInterval(sessionID: session, bookID: book.id, start: instant, end: start.addingTimeInterval(Double(offset + 1) * seconds), duration: seconds,
                    timezoneID: calendar.timeZone.identifier, mode: book.resolvedFormat == .audiobook ? .listening : pages > 0 ? .automatic : .manual, disposition: disposition)
                try store.appendInterval(interval)
                if pages > 0 {
                    let page = 1000 + (calendar.ordinality(of: .day, in: .year, for: date) ?? 1) * 100 + hour * 2 + offset
                    try store.appendEvent(AuditEvent(date: interval.end, kind: "pageTurn", bookID: book.id, sessionID: session, detail: "Synthetic Atlas preview",
                        pageTurn: PageTurnEvidence(fromPage: page, toPage: page + 1, pagesRead: 1, visiblePages: 1, layoutSignature: "atlas-preview")))
                }
            }
            if book.resolvedFormat == .audiobook {
                try store.appendProgress(ProgressObservation(bookID: book.id, observedAt: start.addingTimeInterval(Double(minutes * 60)), source: "local-audiobook", reliable: true,
                    audio: AudiobookProgress(positionSeconds: 10620, durationSeconds: 25080), sessionID: session))
            }
        }
        if fixture == "standard" {
            let year = calendar.dateInterval(of: .year, for: anchor)!.start
            let lastIndex = calendar.dateComponents([.day], from: year, to: anchor).day ?? 0
            for (index, book) in books.enumerated() {
                let first = max(0, lastIndex - (8 - index) * 32)
                let end = min(lastIndex - 1, first + 55)
                if first <= end {
                    for day in first...end where (day + index) % 4 != 0 {
                        let date = calendar.date(byAdding: .day, value: day, to: year)!
                        try record(book, date: date, hour: 8 + index, minutes: 15 + day % 25,
                            pages: book.resolvedFormat == .audiobook ? 0 : 2 + day % 8, suffix: "day-\(day)")
                    }
                    if index < 6 {
                        let date = calendar.date(byAdding: .day, value: end, to: year)!
                        try store.appendEvent(AuditEvent(date: date, kind: "bookCompleted", bookID: book.id, detail: "Synthetic explicit finish",
                            completion: BookCompletionEvidence(finishedAt: date, source: "manual", imported: false)))
                    }
                }
            }
            try record(books[6], date: anchor, hour: 8, minutes: 34, pages: 26, suffix: "morning")
            try record(books[7], date: anchor, hour: 18, minutes: 42, pages: 0, suffix: "audio")
            try record(books[6], date: anchor, hour: 21, minutes: 27, pages: 18, suffix: "evening")
        } else if fixture != "empty" {
            for (index, book) in books.enumerated() {
                try record(book, date: anchor, hour: 7 + index, minutes: fixture == "dense" ? 40 : 20,
                    pages: fixture == "dense" && book.resolvedFormat != .audiobook ? 12 : 0,
                    disposition: fixture == "review" ? .uncertain : .credited, suffix: fixture)
            }
            if fixture == "merged" {
                let target = BookRecord(id: "atlas-target", title: "The Remains of the Day — linked edition", author: "Kazuo Ishiguro")
                try store.saveBook(target); try store.merge(BookMerge(sourceID: books[0].id, targetID: target.id))
            }
        }
        let model = try AppModel(support: support, defaults: defaults, startTracking: false)
        defer { model.shutdown() }
        if fixture == "merged" {
            guard model.readingSessions.allSatisfy({ $0.bookID == "atlas-target" }) else { throw AtlasPreviewFailure.invalidMerge }
        }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for scale in fixture == "standard" ? CalendarScale.allCases : [.day] {
                for width in fixture == "standard" && scale == .day ? [1120, 700] : [1120] {
                    let height = fixture == "dense" ? 1600 : scale == .year ? 1120 : 950
                    let view = HistoryView(model: model, initialScale: scale, anchor: anchor)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let size = NSSize(width: width, height: height)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = NSApp.appearance
                    let host = NSHostingView(rootView: view); host.appearance = NSApp.appearance
                    window.contentView = host; window.orderBack(nil); host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    defer { window.contentView = nil; window.close() }
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AtlasPreviewFailure.render }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AtlasPreviewFailure.render }
                    let name = fixture == "standard" ? scale.rawValue : fixture
                    try data.write(to: destination.appendingPathComponent("atlas-\(name)\(width == 700 ? "-compact" : "")-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
    print("atlas-render: native previews saved to \(destination.path)")
}
private enum AtlasPreviewFailure: Error { case render, invalidMerge }

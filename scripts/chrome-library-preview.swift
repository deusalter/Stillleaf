// Compile with the app sources (with their @main attribute removed) and the
// local BooksCore / BooksPlatform modules. Uses synthetic data only.
import AppKit
import SwiftUI
import BooksCore

@main
struct ChromeLibraryPreview {
    static var reducedMotion = false
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--self-test-ui") { try runUISmoke(); return }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "Stillleaf.ChromePreview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        ThemeStore.shared.reload(from: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let support = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = try ReadingStore(url: support.appendingPathComponent("history.sqlite"))
        let sizes = [NSSize(width: 120, height: 320), NSSize(width: 240, height: 240), NSSize(width: 360, height: 180)]
        var books: [BookRecord] = []
        for (index, size) in sizes.enumerated() {
            let art = NSImage(size: size)
            art.lockFocus()
            [NSColor.systemTeal, .systemOrange, .systemIndigo][index].setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor.white.withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: NSRect(x: size.width * 0.1, y: size.height * 0.3, width: size.width * 0.8, height: size.width * 0.8)).fill()
            art.unlockFocus()
            let path = support.appendingPathComponent("cover-\(index).png")
            let bitmap = NSBitmapImageRep(data: art.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: path)
            let book = BookRecord(id: "cover-\(index)", title: ["Narrow Cover", "A Longer Title That Wraps Across Two Lines", "Wide Cover"][index], author: "Preview Author", coverPath: path.path)
            books.append(book)
            try store.saveBook(book)
            try store.appendProgress(observation(book))
        }
        let model = try AppModel(support: support, defaults: defaults, startTracking: false)
        defer { model.shutdown() }
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let suffix = dark ? "dark" : "light"
            let dashboard = DashboardView(model: model, initialSection: .library).environment(\.colorScheme, scheme)
            try capture(AnyView(dashboard), size: NSSize(width: 1060, height: 760), to: root.appendingPathComponent("window-\(suffix).png"))
            for reduced in [false, true] {
                reducedMotion = reduced
                let cards = VStack(alignment: .leading, spacing: 20) {
                    Text("Resting covers").font(.headline)
                    row(books, hovering: false)
                    Text("Hovered covers · narrow, square, landscape source art").font(.headline)
                    row(books, hovering: true)
                }
                .padding(20).foregroundStyle(ReadingPalette.ink).background(ReadingPalette.paper)
                .environment(\.colorScheme, scheme)
                try capture(AnyView(cards), size: NSSize(width: 660, height: 830), to: root.appendingPathComponent("covers-\(suffix)-\(reduced ? "reduced" : "normal").png"))
            }
        }
        #if !CHROME_BEFORE
        // Reuse one window while changing themes and appearance, as Settings does.
        let live = DashboardWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        live.isReleasedWhenClosed = false
        for theme in ReadingTheme.all {
            ThemeStore.shared.select(theme: theme.id)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                appearance.performAsCurrentDrawingAppearance {
                    let actual = live.backgroundColor.usingColorSpace(.sRGB)!
                    let expected = ReadingPalette.nsColor((dark ? theme.dark : theme.light).canvas)
                    precondition(abs(actual.redComponent - expected.redComponent) < 0.001)
                    precondition(abs(actual.greenComponent - expected.greenComponent) < 0.001)
                    precondition(abs(actual.blueComponent - expected.blueComponent) < 0.001)
                }
            }
        }
        live.close()
        print("chrome-library-preview: live theme switching matched every light/dark canvas")
        #endif
        print("chrome-library-preview: captured native window chrome and actual cards with narrow, square and landscape covers, light/dark and reduced motion")
    }

    static func observation(_ book: BookRecord) -> ProgressObservation {
        ProgressObservation(bookID: book.id, page: book.id == "cover-0" ? 706 : book.id == "cover-1" ? 84 : nil,
            totalPages: book.id == "cover-0" ? 1000 : nil, fraction: book.id == "cover-2" ? 0.42 : nil,
            source: "synthetic preview", reliable: true)
    }

    @MainActor static func row(_ books: [BookRecord], hovering: Bool) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach(books) { book in
                #if CHROME_BEFORE
                BookLibraryCard(book: book, pages: 12, finished: false, date: nil, rating: nil, open: {}, hovering: hovering)
                    .frame(width: 180)
                #else
                BookLibraryCard(book: book, pages: 12, finished: false, date: nil, rating: nil,
                    progress: observation(book), open: {}, hovering: hovering).frame(width: 180)
                #endif
            }
        }
    }

    @MainActor static func capture(_ view: AnyView, size: NSSize, to path: URL) throws {
        #if CHROME_BEFORE
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        #else
        let window = DashboardWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        #endif
        window.title = "Stillleaf"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let frame = window.contentView!.superview!
        frame.layoutSubtreeIfNeeded()
        frame.displayIfNeeded()
        let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
        precondition(window.standardWindowButton(.closeButton) != nil)
        precondition(window.standardWindowButton(.miniaturizeButton) != nil)
        precondition(window.standardWindowButton(.zoomButton) != nil)
        precondition(window.isMovable)
        window.contentView = nil
        window.close()
    }
}

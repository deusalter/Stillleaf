import AppKit
import SwiftUI
import BooksCore

/// `--capture-window-chrome <dir>`
///
/// Builds the dashboard and reader windows the way the app does, with synthetic history, and
/// checks that each is one unified window: a transparent title bar with no separator, the
/// dashboard's garden and sidebar running under it, the title bar still answering drags and
/// double-clicks itself, and the traffic lights on the sidebar. Saves composited captures in
/// light and dark mode and writes `window-chrome.json`. Windows are parked by background mode.
@MainActor
func captureWindowChrome(to destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-chrome-\(UUID().uuidString)")
    let suite = "Stillleaf.WindowChrome.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set("America/Los_Angeles", forKey: "timezoneID")
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: support)
        ThemeStore.shared.reload(from: .standard)
    }
    ThemeStore.shared.reload(from: defaults)
    try seedPreviewHistory(at: support)
    let model = try AppModel(support: support, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    var report: [String: Any] = [:]
    var failures: [String] = []
    for dark in [false, true] {
        let name = dark ? "dark" : "light"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let dashboard = makeChromeDashboardWindow()
        dashboard.appearance = appearance
        dashboard.contentViewController = NSHostingController(rootView: DashboardView(model: model, initialSection: .today))
        dashboard.setContentSize(NSSize(width: 1060, height: 760))
        dashboard.makeKeyAndOrderFront(nil)
        settle(for: 2.5)
        let facts = chromeFacts(dashboard)
        report["dashboard-\(name)"] = facts
        failures += unifiedChromeFailures(facts, window: "dashboard-\(name)", expectsFullSize: true)
        try captureChrome(dashboard, to: destination.appendingPathComponent("dashboard-\(name).png"))
        dashboard.contentViewController = nil
        dashboard.close()

        // The reader's page is a web view; a plain view in the default page colour stands in for it.
        let page = dark ? "#000000" : "#FFFFFF"
        let reader = makeChromeReaderWindow(title: "The Waves", page: page)
        reader.appearance = appearance
        let chrome = NativeReaderChrome(window: reader)
        // What the renderer reports on connecting, so the toolbar is drawn for this page.
        chrome.accept(["effectiveAppearance": ["backgroundColor": page, "textColor": dark ? "#ECECEE" : "#111113"],
                       "panelAppearance": ["panelColor": dark ? "#111113" : "#FAFAFB", "accentColor": dark ? "#A3C4F0" : "#0A57AD"]])
        chrome.toolbar.isVisible = true
        applyChromeReaderPage(page, to: reader)
        reader.makeKeyAndOrderFront(nil)
        settle(for: 1.0)
        let readerFacts = chromeFacts(reader)
        report["reader-\(name)"] = readerFacts
        failures += unifiedChromeFailures(readerFacts, window: "reader-\(name)", expectsFullSize: false)
        if readerFacts["fullSizeContentView"] as? Bool != true || readerFacts["contentReachesTop"] as? Bool != true {
            failures.append("reader-\(name): the page does not run under the title bar")
        }
        try captureChrome(reader, to: destination.appendingPathComponent("reader-\(name).png"))
        chrome.disconnect()
        reader.close()
    }
    report["failures"] = failures
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: destination.appendingPathComponent("window-chrome.json"))
    print(String(decoding: data, as: UTF8.self))
    if !failures.isEmpty && !CommandLine.arguments.contains("--report-only") {
        throw WindowChromeCaptureError.notUnified(failures)
    }
}

private enum WindowChromeCaptureError: Error { case notUnified([String]); case captureFailed }

// MARK: Windows as the app builds them

@MainActor private func makeChromeDashboardWindow() -> NSWindow { DashboardWindow.make() }

@MainActor private func makeChromeReaderWindow(title: String, page: String) -> NSWindow {
    let window = ReaderWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = title
    ReaderTitlebar.configure(window)
    window.contentView = ChromePageStandIn(color: ReaderTitlebar.color(hex: page) ?? .white)
    return window
}

@MainActor private func applyChromeReaderPage(_ page: String, to window: NSWindow) {
    ReaderTitlebar.follow(page: ["backgroundColor": page], in: window)
}

// MARK: Checks

private final class ChromePageStandIn: NSView {
    let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); dirtyRect.fill() }
}

@MainActor private func settle(for seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) }
}

@MainActor private func captureChrome(_ window: NSWindow, to url: URL) throws {
    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw WindowChromeCaptureError.captureFailed }
    try png.write(to: url)
}

/// What answers a click at `point` (window coordinates): the title bar (its own views, or the
/// dashboard routing a press in the band as one), or the content.
@MainActor private func hitOwner(_ window: NSWindow, _ point: NSPoint) -> String {
    if let dashboard = window as? DashboardWindow, dashboard.treatsAsTitlebar(point) { return "titlebar" }
    if let reader = window as? ReaderWindow, reader.treatsAsTitlebar(point) { return "titlebar" }
    guard let frame = window.contentView?.superview, let hit = frame.hitTest(frame.convert(point, from: nil)) else { return "none" }
    var view: NSView? = hit
    while let current = view {
        if String(describing: type(of: current)).contains("Titlebar") { return "titlebar" }
        if current === window.contentView { return "content" }
        view = current.superview
    }
    return String(describing: type(of: hit))
}

/// Double-clicks the title bar band over the page with real events and reports whether the window
/// asked to zoom. The probe delegate refuses, so nothing moves on screen.
@MainActor private func doubleClickZooms(_ window: NSWindow) -> Bool {
    final class Probe: NSObject, NSWindowDelegate {
        var asked = false
        func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { asked = true; return false }
    }
    let probe = Probe(), previous = window.delegate
    window.delegate = probe
    defer { window.delegate = previous }
    let layout = window.contentLayoutRect
    let point = NSPoint(x: window.frame.width * 0.6, y: (layout.maxY + window.frame.height) / 2)
    for count in [2] {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        // Queue the release first, so a title bar that tracks the press sees it end at once.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        settle(for: 0.05)
    }
    return probe.asked
}

@MainActor private func chromeFacts(_ window: NSWindow) -> [String: Any] {
    let height = window.frame.height
    let layout = window.contentLayoutRect
    let titlebarHeight = height - layout.maxY
    var facts: [String: Any] = [
        "titlebarAppearsTransparent": window.titlebarAppearsTransparent,
        "fullSizeContentView": window.styleMask.contains(.fullSizeContentView),
        "separatorNone": window.titlebarSeparatorStyle == .none,
        "toolbarVisible": window.toolbar?.isVisible ?? false,
        "titlebarHeight": Double(titlebarHeight),
        "titleVisible": window.titleVisibility == .visible,
        // Points in the title bar band: over the sidebar and over the page.
        "hitOverSidebarTop": hitOwner(window, NSPoint(x: 160, y: height - titlebarHeight / 2)),
        "hitOverPageTop": hitOwner(window, NSPoint(x: window.frame.width * 0.6, y: height - titlebarHeight / 2)),
        "hitBelowTitlebar": hitOwner(window, NSPoint(x: window.frame.width * 0.6, y: layout.maxY - 40)),
        "contentReachesTop": (window.contentView.map { $0.convert($0.bounds, to: nil).maxY } ?? 0) >= height - 0.5,
        "doubleClickZooms": window is DashboardWindow ? doubleClickZooms(window) as Any : NSNull()
    ]
    if let close = window.standardWindowButton(.closeButton) {
        let rect = close.convert(close.bounds, to: nil)
        facts["closeButton"] = [Double(rect.minX), Double(height - rect.maxY), Double(rect.width), Double(rect.height)]
        if let sidebar = findView(window.contentView, identifier: DashboardSidebarProbe.identifier) {
            let panel = sidebar.convert(sidebar.bounds, to: nil)
            facts["sidebarPanel"] = [Double(panel.minX), Double(height - panel.maxY), Double(panel.width), Double(panel.height)]
            facts["trafficLightsOnSidebar"] = panel.insetBy(dx: -0.5, dy: -0.5).contains(rect)
        }
    }
    return facts
}

private func findView(_ root: NSView?, identifier: NSUserInterfaceItemIdentifier) -> NSView? {
    guard let root else { return nil }
    if root.identifier == identifier { return root }
    for child in root.subviews { if let found = findView(child, identifier: identifier) { return found } }
    return nil
}

private func unifiedChromeFailures(_ facts: [String: Any], window: String, expectsFullSize: Bool) -> [String] {
    var failures: [String] = []
    if facts["titlebarAppearsTransparent"] as? Bool != true { failures.append("\(window): the title bar is opaque, so it draws its own strip") }
    if facts["separatorNone"] as? Bool != true { failures.append("\(window): the title bar draws a separator line") }
    if facts["hitOverPageTop"] as? String != "titlebar" { failures.append("\(window): the title bar over the page does not take drags and double-clicks") }
    if facts["hitBelowTitlebar"] as? String == "titlebar" { failures.append("\(window): the title bar takes clicks below its band") }
    if expectsFullSize {
        if facts["fullSizeContentView"] as? Bool != true || facts["contentReachesTop"] as? Bool != true {
            failures.append("\(window): the content does not run under the title bar")
        }
        // The dashboard routes presses in the band itself, so its double-click is checked end to end.
        // The reader's band belongs to AppKit's own title bar view, which ignores synthesized events.
        if facts["doubleClickZooms"] as? Bool != true { failures.append("\(window): double-clicking the title bar does not zoom") }
        if facts["hitOverSidebarTop"] as? String != "titlebar" { failures.append("\(window): the title bar over the sidebar does not take drags") }
        if facts["trafficLightsOnSidebar"] as? Bool != true { failures.append("\(window): the traffic lights are not on the sidebar") }
    }
    return failures
}

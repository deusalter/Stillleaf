import AppKit
import SwiftUI

/// Synthetic decorated-window captures; no production stores or Mac permissions.
@MainActor func renderNativeChromePreviews(directory: URL) throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-native-preview-" + UUID().uuidString)
    let suite = "Stillleaf.NativePreview." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: temporary); defaults.removePersistentDomain(forName: suite) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = try AppModel(support: temporary, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    for dark in [false, true] {
        for opaque in [false, true] {
            let window = DashboardWindow(contentRect: NSRect(x: 100, y: 100, width: 1060, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Stillleaf — synthetic preview"
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentViewController = NSHostingController(rootView: DashboardView(model: model).environment(\.accessibilityReduceTransparency, opaque).environment(\.accessibilityReduceMotion, true))
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let toolbar = window.toolbar, toolbar.items.filter({ $0.itemIdentifier.rawValue.contains("toggleSidebar") }).count == 1 else { throw UIPreviewError.renderFailed }
            try captureNativeWindow(window, to: directory.appendingPathComponent("dashboard-\(dark ? "dark" : "light")-\(opaque ? "opaque" : "system").png"))
            window.contentViewController = nil; window.close()
            let panel = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 350, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.title = "Stillleaf — synthetic menu panel"; panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            panel.contentViewController = NSHostingController(rootView: PopoverView(model: model).environment(\.accessibilityReduceTransparency, opaque).environment(\.accessibilityReduceMotion, true))
            panel.orderBack(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            try captureNativeWindow(panel, to: directory.appendingPathComponent("panel-\(dark ? "dark" : "light")-\(opaque ? "opaque" : "system").png"))
            panel.contentViewController = nil; panel.close()
        }
    }
    #if compiler(>=6.2)
    if #available(macOS 26, *) { print("native-chrome-preview: genuine SwiftUI glass compiled; macOS26 runtime; solid accessibility fallback captured") }
    else { print("native-chrome-preview: modern binary fallback runtime") }
    #else
    print("native-chrome-preview: compatibility SDK native material runtime")
    #endif
}

@MainActor func captureNativeWindow(_ window: NSWindow, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let frame = window.contentView?.superview else { throw UIPreviewError.renderFailed }
    frame.layoutSubtreeIfNeeded(); frame.displayIfNeeded()
    guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { throw UIPreviewError.renderFailed }
    frame.cacheDisplay(in: frame.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw UIPreviewError.renderFailed }
    try data.write(to: url)
}

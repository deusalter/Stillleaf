import AppKit
import SwiftUI
@preconcurrency import ScreenCaptureKit

private enum NativeChromeCaptureError: Error { case renderFailed }

/// Synthetic decorated-window captures; no production stores or Mac permissions.
@MainActor func renderNativeChromePreviews(directory: URL) async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-native-preview-" + UUID().uuidString)
    let suite = "Stillleaf.NativePreview." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: temporary); defaults.removePersistentDomain(forName: suite) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    NSApp.setActivationPolicy(.regular)
    let model = try AppModel(support: temporary, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    for dark in [false, true] {
        for opaque in [false, true] {
            let window = DashboardWindow(contentRect: NSRect(x: 100, y: 100, width: 1060, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Stillleaf — synthetic preview"
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentViewController = NSHostingController(rootView: DashboardView(model: model).environment(\.nativePreviewOpaque, opaque))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(nanoseconds: 400_000_000)
            guard let toolbar = window.toolbar, toolbar.items.filter({ $0.itemIdentifier.rawValue.contains("toggleSidebar") }).count == 1 else { throw NativeChromeCaptureError.renderFailed }
            try await captureNativeWindow(window, to: directory.appendingPathComponent("dashboard-\(dark ? "dark" : "light")-\(opaque ? "opaque" : "system").png"))
            window.contentViewController = nil; window.close()
            let panel = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 350, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.title = "Stillleaf — synthetic menu panel"; panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            panel.contentViewController = NSHostingController(rootView: PopoverView(model: model).environment(\.nativePreviewOpaque, opaque))
            panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); try await Task.sleep(nanoseconds: 300_000_000)
            try await captureNativeWindow(panel, to: directory.appendingPathComponent("panel-\(dark ? "dark" : "light")-\(opaque ? "opaque" : "system").png"))
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

@MainActor func captureNativeWindow(_ window: NSWindow, to url: URL) async throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if #available(macOS 14.0, *) {
        let originalOrigin = window.frame.origin
        defer { window.setFrameOrigin(originalOrigin) }
        window.setFrameOrigin(NSPoint(x: 100, y: 100)); window.orderFront(nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let owned = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw NativeChromeCaptureError.renderFailed }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * (window.screen?.backingScaleFactor ?? 1))
            config.height = Int(window.frame.height * (window.screen?.backingScaleFactor ?? 1))
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: owned), configuration: config)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw NativeChromeCaptureError.renderFailed }
            try data.write(to: url)
            print("native-capture: compositor own-window \(url.lastPathComponent)")
            return
        } catch {
            let detail = "Compositor capture unavailable for synthetic window: \(error). View cache is diagnostic only and cannot establish material appearance."
            try detail.write(to: url.appendingPathExtension("unavailable.txt"), atomically: true, encoding: .utf8)
            print(detail)
        }
    }
    guard let frame = window.contentView?.superview else { throw NativeChromeCaptureError.renderFailed }
    frame.layoutSubtreeIfNeeded(); frame.displayIfNeeded()
    guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { throw NativeChromeCaptureError.renderFailed }
    frame.cacheDisplay(in: frame.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NativeChromeCaptureError.renderFailed }
    try data.write(to: url.deletingPathExtension().appendingPathExtension("view-cache.png"))
}

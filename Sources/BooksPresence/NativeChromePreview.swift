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
    try seedPreviewHistory(at: temporary)
    NSApp.setActivationPolicy(.regular)
    let model = try AppModel(support: temporary, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    for dark in [false, true] {
        for opaque in [false, true] {
            let window = DashboardWindow(contentRect: NSRect(x: 100, y: 100, width: 1060, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Stillleaf — synthetic preview"
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentViewController = NSHostingController(rootView: DashboardView(model: model, initialSection: .library).environment(\.nativePreviewOpaque, opaque))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            // Hosting installs toolbar items asynchronously. Check real readiness for
            // the modern-built package on older runtimes, not a fixed capture delay.
            let deadline = Date().addingTimeInterval(3)
            func sidebarToolbarReady() -> Bool {
                if #available(macOS 14.0, *) { return dashboardSidebarToggleButtons(in: window).count == 1 }
                return window.toolbar?.items.filter { $0.itemIdentifier.rawValue.contains("toggleSidebar") }.count == 1
            }
            while Date() < deadline && !sidebarToolbarReady() {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let identifiers = window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []
            print("native-dashboard-toolbar: installed=\(window.toolbar != nil) items=\(identifiers)")
            guard window.toolbar != nil, sidebarToolbarReady() else { throw NativeChromeCaptureError.renderFailed }
            try await captureNativeWindow(window, to: directory.appendingPathComponent("dashboard-\(dark ? "dark" : "light")-\(opaque ? "opaque" : "system").png"))
            window.contentViewController = nil; window.close()
            // An app-owned text backdrop exercises popover readability without
            // collecting desktop content or any real reading data.
            let backdrop = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 600, height: 650),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
            backdrop.isReleasedWhenClosed = false
            backdrop.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            backdrop.contentViewController = NSHostingController(rootView: NativePopoverBackdrop())
            backdrop.orderFront(nil)
            let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 350, height: 500), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isReleasedWhenClosed = false; panel.title = "Stillleaf — synthetic menu panel"; panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            panel.contentViewController = NSHostingController(rootView: PopoverView(model: model).environment(\.nativePreviewOpaque, opaque))
            panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); try await Task.sleep(nanoseconds: 300_000_000)
            try await captureNativeWindow(panel, to: directory.appendingPathComponent("panel-\(dark ? "dark" : "light")-\(opaque ? "opaque" : "system").png"), contextWindow: backdrop)
            panel.contentViewController = nil; panel.close()
            backdrop.contentViewController = nil; backdrop.close()
            try await checkMenuPickerLayout(directory: directory, dark: dark, opaque: opaque)
        }
        // Exercise glass at the supported minimum too. An explicit app-owned
        // override keeps runner accessibility defaults from silently selecting
        // our solid fallback; the separate opaque captures cover that branch.
        for section in [DashboardSection.today, .library, .timeline, .history, .review, .settings] {
            let window = DashboardWindow(contentRect: NSRect(x: 100, y: 100, width: 920, height: 660),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Stillleaf — synthetic compact preview"
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentViewController = NSHostingController(rootView: DashboardView(model: model, initialSection: section)
                .environment(\.nativePreviewOpaque, false))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await captureNativeWindow(window, to: directory.appendingPathComponent(
                "compact-\(section.rawValue)-\(dark ? "dark" : "light").png"))
            window.contentViewController = nil; window.close()
        }
        let listeningWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 550, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        listeningWindow.isReleasedWhenClosed = false
        listeningWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        listeningWindow.contentViewController = NSHostingController(rootView:
            AudiobookLogView(model: model, maximumHeight: 500, initiallyIncludesSession: true)
                .environment(\.nativePreviewOpaque, false))
        listeningWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await captureNativeWindow(listeningWindow, to: directory.appendingPathComponent(
            "compact-listening-\(dark ? "dark" : "light").png"))
        listeningWindow.contentViewController = nil; listeningWindow.close()
        let yearWindow = DashboardWindow(contentRect: NSRect(x: 100, y: 100, width: 920, height: 660),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        yearWindow.isReleasedWhenClosed = false
        yearWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        yearWindow.contentViewController = NSHostingController(rootView:
            DashboardView(model: model, initialSection: .history, initialCalendarScale: .year)
                .environment(\.nativePreviewOpaque, false))
        yearWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await captureNativeWindow(yearWindow, to: directory.appendingPathComponent(
            "compact-year-\(dark ? "dark" : "light").png"))
        yearWindow.contentViewController = nil; yearWindow.close()
        try await checkRecordedDateKeyboardFocus(directory: directory, dark: dark)
        try await checkDashboardSidebarNavigation(model: model, directory: directory, dark: dark)
    }
    try await checkStatusMenuPanelInteractions(directory: directory)
    #if compiler(>=6.2)
    if #available(macOS 26, *) { print("native-chrome-preview: genuine SwiftUI glass compiled; macOS26 runtime; app-owned solid fallback captured (system accessibility settings unchanged)") }
    else { print("native-chrome-preview: modern binary fallback runtime") }
    #else
    print("native-chrome-preview: compatibility SDK native material runtime")
    #endif
}

private struct NativePopoverBackdrop: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(0..<10) { _ in
                Text("Synthetic background text\nA quiet place to return to your reading.")
                    .font(.system(size: 24, weight: .medium))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Color.primary)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MenuPickerWidthPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

@MainActor private final class MenuPickerLayoutProbe { var width: CGFloat = 0 }

@MainActor private struct LongTitlePickerFixture: View {
    let width: CGFloat
    let probe: MenuPickerLayoutProbe
    @State private var selection = 0
    private let titles = [
        "A Very Long Book Title: Collected Letters, Notes, and Recollections from a Journey Across the World — Revised and Expanded Edition",
        "A Short Title"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Book").font(.headline)
            ReadingMenuPicker(label: "Book", options: Array(titles.indices), selection: $selection) { titles[$0] }
                // Measure before the enclosing form's fixed width can mask an
                // overflowing child. This catches the old horizontal fixedSize.
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MenuPickerWidthPreference.self, value: geometry.size.width)
                })
                .onPreferenceChange(MenuPickerWidthPreference.self) { probe.width = $0 }
            Button("Done") { }.buttonStyle(ReadingButtonStyle())
        }
        .padding(24)
        .frame(width: width, height: 180, alignment: .topLeading)
        .background(ReadingPalette.paper)
        .foregroundStyle(ReadingPalette.ink)
    }
}

@MainActor private func checkMenuPickerLayout(directory: URL, dark: Bool, opaque: Bool) async throws {
    // Merge's 480-point sheet and a narrower available form column.
    for width in [CGFloat(480), CGFloat(360)] {
        let probe = MenuPickerLayoutProbe()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = NSHostingController(rootView:
            LongTitlePickerFixture(width: width, probe: probe).environment(\.nativePreviewOpaque, opaque))
        window.makeKeyAndOrderFront(nil)
        let deadline = Date().addingTimeInterval(3)
        while probe.width == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await captureNativeWindow(window, to: directory.appendingPathComponent(
            "long-title-\(Int(width))-\(dark ? "dark" : "light")-\(opaque ? "opaque" : "system").png"))
        let available = width - 48
        print("native-menu-layout: form=\(width) available=\(available) menu=\(probe.width)")
        guard probe.width > 0, probe.width <= available + 1 else { throw NativeChromeCaptureError.renderFailed }
    }
}

@MainActor func captureNativeWindow(_ window: NSWindow, to url: URL, contextWindow: NSWindow? = nil) async throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if #available(macOS 14.0, *) {
        let originalOrigin = window.frame.origin
        defer { window.setFrameOrigin(originalOrigin) }
        var captureOrigin = NSPoint(x: 100, y: 100)
        if contextWindow != nil, let screen = window.screen ?? NSScreen.main {
            // Display-space captures cannot include pixels beyond the screen.
            // Keep the whole window visible without changing its actual size.
            let bounds = screen.visibleFrame
            captureOrigin.x = max(bounds.minX, min(captureOrigin.x, bounds.maxX - window.frame.width))
            captureOrigin.y = max(bounds.minY, min(captureOrigin.y, bounds.maxY - window.frame.height))
        }
        window.setFrameOrigin(captureOrigin)
        window.orderFront(nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let owned = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw NativeChromeCaptureError.renderFailed }
            let config = SCStreamConfiguration()
            // A system popover belongs to a capture window group. Its filtered
            // content rectangle can include the parent, unlike SCWindow.frame.
            // Use the filter's native pixel geometry rather than scaling that
            // group into the smaller AppKit popup's dimensions.
            let filter: SCContentFilter
            let captureSize: CGSize
            if let contextWindow {
                // Single-window capture groups a transient popup with its
                // parent but reports only the popup bounds. Use display-space
                // capture filtered to these two synthetic owned windows and
                // crop the actual popup rectangle, without desktop content.
                guard let parent = content.windows.first(where: { $0.windowID == CGWindowID(contextWindow.windowNumber) }),
                      let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: owned.frame.midX, y: owned.frame.midY)) }) else { throw NativeChromeCaptureError.renderFailed }
                filter = SCContentFilter(display: display, including: [parent, owned])
                config.sourceRect = owned.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                captureSize = owned.frame.size
            } else {
                filter = SCContentFilter(desktopIndependentWindow: owned)
                captureSize = filter.contentRect.size
            }
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(captureSize.width * scale)
            config.height = Int(captureSize.height * scale)
            print("native-capture-geometry: AppKit=\(window.frame.size) window=\(owned.frame.size) filter=\(filter.contentRect) scale=\(scale) output=\(config.width)x\(config.height)")
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
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

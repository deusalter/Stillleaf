import AppKit
import SwiftUI

private enum DashboardSidebarSmokeError: Error { case failed(String) }

@MainActor
func dashboardSidebarToggleButtons(in window: NSWindow) -> [NSButton] {
    var buttons: [NSButton] = []
    var visited: Set<ObjectIdentifier> = []
    func visit(_ view: NSView) {
        guard visited.insert(ObjectIdentifier(view)).inserted else { return }
        if let button = view as? NSButton, button.identifier?.rawValue == "dashboard-sidebar-toggle" { buttons.append(button) }
        for child in view.subviews { visit(child) }
    }
    if let frame = window.contentView?.superview { visit(frame) }
    for item in window.toolbar?.items ?? [] { if let view = item.view { visit(view) } }
    return buttons
}

@MainActor
private func dashboardSidebarGeometry(in window: NSWindow) -> (collapsed: Bool, width: CGFloat)? {
    func find(_ view: NSView) -> NSView? {
        if view.identifier == DashboardSidebarProbe.identifier { return view }
        for child in view.subviews { if let found = find(child) { return found } }
        return nil
    }
    // The floating glass sidebar leaves the hierarchy when it is hidden.
    guard let root = window.contentView else { return nil }
    guard let sidebar = find(root), sidebar.window != nil else { return (true, 0) }
    return (sidebar.frame.width < 2, sidebar.frame.width)
}

@MainActor
private func dashboardSidebarIsCollapsed(in window: NSWindow) -> Bool? {
    dashboardSidebarGeometry(in: window)?.collapsed
}

/// Exercise the real native control and split view, recording its physical
/// titlebar position after pointer, keyboard and Reduce Motion toggles.
@MainActor
func checkDashboardSidebarNavigation(model: AppModel, directory: URL, dark: Bool) async throws {
    guard #available(macOS 14.0, *) else { return }
    if ProcessInfo.processInfo.environment["STILLLEAF_PREVIEW_EXPECT_SYSTEM_GLASS"] == "1" {
        let workspace = NSWorkspace.shared
        guard !workspace.accessibilityDisplayShouldReduceTransparency,
              !workspace.accessibilityDisplayShouldReduceMotion else {
            throw DashboardSidebarSmokeError.failed("Runner did not enable actual native effects: reduceTransparency=\(workspace.accessibilityDisplayShouldReduceTransparency) reduceMotion=\(workspace.accessibilityDisplayShouldReduceMotion)")
        }
    }
    let backdrop = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 1300, height: 900),
        styleMask: [.borderless], backing: .buffered, defer: false)
    backdrop.isReleasedWhenClosed = false
    if let screen = NSScreen.main { backdrop.setFrame(screen.frame, display: false) }
    backdrop.orderFront(nil)
    defer { backdrop.close() }
    for reducedMotion in [false, true] {
        backdrop.backgroundColor = NSColor(calibratedRed: 0.83, green: 0.40, blue: 0.21, alpha: 1)
        let window = DashboardWindow(contentRect: NSRect(x: 100, y: 100, width: 1060, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Stillleaf"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let controller = NSHostingController(rootView: DashboardView(model: model, initialSection: .library)
            .environment(\.nativePreviewOpaque, false)
            .environment(\.nativePreviewReduceMotion, reducedMotion))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1060, height: 760))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.contentViewController = nil; window.close() }

        func waitForSidebar(collapsed: Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let buttons = dashboardSidebarToggleButtons(in: window)
                if buttons.count == 1, dashboardSidebarIsCollapsed(in: window) == collapsed,
                   buttons[0].toolTip == (collapsed ? "Show sidebar" : "Hide sidebar") {
                    // The visibility binding settles before native glass has
                    // finished resizing its compositor layers. Capture the
                    // resting controls, not that intermediate presentation.
                    if !reducedMotion { try await Task.sleep(nanoseconds: 350_000_000) }
                    if !collapsed {
                        let width = dashboardSidebarGeometry(in: window)?.width ?? 0
                        guard width >= 205 - 1, width <= 260 + 1 else {
                            throw DashboardSidebarSmokeError.failed("Expanded sidebar width outside 205–260 pt: \(width)")
                        }
                    }
                    return
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw DashboardSidebarSmokeError.failed("Sidebar state did not settle: expectedCollapsed=\(collapsed) actual=\(String(describing: dashboardSidebarIsCollapsed(in: window))) buttons=\(dashboardSidebarToggleButtons(in: window).count)")
        }
        try await waitForSidebar(collapsed: false)
        guard let button = dashboardSidebarToggleButtons(in: window).first else { throw DashboardSidebarSmokeError.failed("Missing native sidebar button") }
        let before = button.convert(button.bounds, to: nil)
        let mode = reducedMotion ? "reduced-motion" : "animated"
        let appearance = dark ? "dark" : "light"
        try await captureNativeWindow(window, to: directory.appendingPathComponent("sidebar-expanded-\(appearance)-\(mode).png"), contextWindow: backdrop)
        button.performClick(nil)
        try await waitForSidebar(collapsed: true)
        // Capture waits for the compositor after the visibility state settles.
        try await captureNativeWindow(window, to: directory.appendingPathComponent("sidebar-collapsed-\(appearance)-\(mode).png"), contextWindow: backdrop)
        guard let collapsedButton = dashboardSidebarToggleButtons(in: window).first else { throw DashboardSidebarSmokeError.failed("Sidebar toggle disappeared after collapse") }
        let collapsed = collapsedButton.convert(collapsedButton.bounds, to: nil)
        guard abs(before.minX - collapsed.minX) < 1, abs(before.minY - collapsed.minY) < 1,
              abs(before.width - collapsed.width) < 1, abs(before.height - collapsed.height) < 1 else {
            throw DashboardSidebarSmokeError.failed("Sidebar toggle moved: expanded=\(before) collapsed=\(collapsed)")
        }
        guard window.makeFirstResponder(collapsedButton), window.firstResponder === collapsedButton else {
            throw DashboardSidebarSmokeError.failed("Native sidebar control did not accept keyboard focus")
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let space = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else {
                throw DashboardSidebarSmokeError.failed("Could not construct sidebar Space key event")
            }
            window.sendEvent(space)
        }
        try await waitForSidebar(collapsed: false)
        try await captureNativeWindow(window, to: directory.appendingPathComponent("sidebar-reopened-\(appearance)-\(mode).png"), contextWindow: backdrop)
        let afterButton = dashboardSidebarToggleButtons(in: window)[0]
        let after = afterButton.convert(afterButton.bounds, to: nil)
        guard abs(before.minX - after.minX) < 1, abs(before.minY - after.minY) < 1 else {
            throw DashboardSidebarSmokeError.failed("Reopening shifted the leading toggle: before=\(before) after=\(after)")
        }
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1),
              window.performKeyEquivalent(with: key) else {
            throw DashboardSidebarSmokeError.failed("Window did not route the sidebar keyboard equivalent")
        }
        try await waitForSidebar(collapsed: true)
        dashboardSidebarToggleButtons(in: window)[0].performClick(nil)
        try await waitForSidebar(collapsed: false)
        let systemToggleCount = window.toolbar?.items.filter { $0.itemIdentifier.rawValue.lowercased().contains("togglesidebar") }.count ?? 0
        guard systemToggleCount == 0 else { throw DashboardSidebarSmokeError.failed("Duplicate system sidebar toggle remained") }
        if !reducedMotion {
            try writeSidebarMaterialDiagnostics(window: window, to: directory.appendingPathComponent("sidebar-\(appearance)-material.json"))
            backdrop.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.37, blue: 0.76, alpha: 1)
            try await captureNativeWindow(window, to: directory.appendingPathComponent("sidebar-cool-backdrop-\(appearance).png"), contextWindow: backdrop)
            window.orderOut(nil)
            try await captureSidebarMaterialReferences(backdrop: backdrop, directory: directory, dark: dark)
        }
        let report: [String: Any] = ["expanded": NSStringFromRect(before), "collapsed": NSStringFromRect(collapsed),
            "reopened": NSStringFromRect(after), "keyboardEquivalent": true, "spaceActivation": true, "reduceMotion": reducedMotion,
            "nativeToggleCount": dashboardSidebarToggleButtons(in: window).count, "defaultToggleCount": systemToggleCount,
            "expandedSidebarWidth": dashboardSidebarGeometry(in: window)?.width ?? 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("sidebar-toggle-\(appearance)-\(mode).json"))
        print("sidebar-toggle: fixed native position, pointer and keyboard passed; \(appearance) \(mode)")
    }
}

/// Public AppKit state lets the capture distinguish an opaque OS accessibility
/// fallback from an app-painted background or the wrong sampling mode.
@MainActor
private func writeSidebarMaterialDiagnostics(window: NSWindow, to url: URL) throws {
    let workspace = NSWorkspace.shared
    var views: [[String: Any]] = []
    func visit(_ view: NSView, depth: Int) {
        var record: [String: Any] = [
            "depth": depth, "class": NSStringFromClass(type(of: view)),
            "frame": NSStringFromRect(view.frame), "bounds": NSStringFromRect(view.bounds),
            "opaque": view.isOpaque, "hidden": view.isHidden, "alpha": view.alphaValue,
            "appearance": view.effectiveAppearance.name.rawValue,
            "layerClass": view.layer.map { NSStringFromClass(type(of: $0)) } ?? "none",
            "layerBackground": String(describing: view.layer?.backgroundColor),
            "layerOpaque": view.layer?.isOpaque ?? false
        ]
        if let material = view as? NSVisualEffectView {
            record["material"] = material.material.rawValue
            record["blendingMode"] = material.blendingMode == .behindWindow ? "behindWindow" : "withinWindow"
            record["state"] = material.state.rawValue
            record["emphasized"] = material.isEmphasized
        }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            record["glassStyle"] = String(describing: glass.style)
            record["glassTint"] = String(describing: glass.tintColor)
        }
        #endif
        views.append(record)
        for child in view.subviews { visit(child, depth: depth + 1) }
    }
    if let root = window.contentView?.superview { visit(root, depth: 0) }
    let report: [String: Any] = [
        "actualReduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency,
        "actualIncreaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast,
        "actualReduceMotion": workspace.accessibilityDisplayShouldReduceMotion,
        "windowOpaque": window.isOpaque, "windowBackground": String(describing: window.backgroundColor),
        "windowAlpha": window.alphaValue, "windowFrame": NSStringFromRect(window.frame),
        "windowKey": window.isKeyWindow, "appActive": NSApp.isActive,
        "views": views
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    print("sidebar-material: actual reduceTransparency=\(workspace.accessibilityDisplayShouldReduceTransparency) increaseContrast=\(workspace.accessibilityDisplayShouldIncreaseContrast) reduceMotion=\(workspace.accessibilityDisplayShouldReduceMotion)")
}

/// A native material with no SwiftUI hierarchy provides an independent control
/// for the same compositor capture and actual system accessibility settings.
@MainActor
private func captureSidebarMaterialReferences(backdrop: NSWindow, directory: URL, dark: Bool) async throws {
    let originalColor = backdrop.backgroundColor
    defer { backdrop.backgroundColor = originalColor }
    var references: [(String, NSView)] = []
    let bounds = NSRect(x: 0, y: 0, width: 280, height: 240)
    let material = NSVisualEffectView(frame: bounds)
    material.material = .sidebar
    material.blendingMode = .behindWindow
    material.state = .active
    references.append(("appkit-sidebar", material))
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(frame: bounds)
        glass.contentView = NSView(frame: bounds)
        references.append(("appkit-glass", glass))
    }
    #endif
    for (name, view) in references {
        let window = NSWindow(contentRect: bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let appearance = dark ? "dark" : "light"
        for (colorName, color) in [
            ("warm", NSColor(calibratedRed: 0.83, green: 0.40, blue: 0.21, alpha: 1)),
            ("cool", NSColor(calibratedRed: 0.12, green: 0.37, blue: 0.76, alpha: 1))
        ] {
            backdrop.backgroundColor = color
            try await captureNativeWindow(window, to: directory.appendingPathComponent("\(name)-\(appearance)-\(colorName).png"), contextWindow: backdrop)
        }
        try writeSidebarMaterialDiagnostics(window: window, to: directory.appendingPathComponent("\(name)-\(appearance)-material.json"))
    }
}

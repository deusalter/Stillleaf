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
private func dashboardSidebarIsCollapsed(in window: NSWindow) -> Bool? {
    func find(_ view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2 { return split }
        for child in view.subviews { if let found = find(child) { return found } }
        return nil
    }
    guard let root = window.contentView, let split = find(root), let sidebar = split.arrangedSubviews.first else { return nil }
    return split.isSubviewCollapsed(sidebar) || sidebar.frame.width < 2
}

/// Exercise the real native control and split view, recording its physical
/// titlebar position after pointer, keyboard and Reduce Motion toggles.
@MainActor
func checkDashboardSidebarNavigation(model: AppModel, directory: URL, dark: Bool) async throws {
    guard #available(macOS 14.0, *) else { return }
    let backdrop = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 1300, height: 900),
        styleMask: [.borderless], backing: .buffered, defer: false)
    backdrop.isReleasedWhenClosed = false
    backdrop.backgroundColor = NSColor(calibratedRed: 0.83, green: 0.40, blue: 0.21, alpha: 1)
    backdrop.orderFront(nil)
    defer { backdrop.close() }
    for reducedMotion in [false, true] {
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
                   buttons[0].toolTip == (collapsed ? "Show sidebar" : "Hide sidebar") { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw DashboardSidebarSmokeError.failed("Sidebar state did not settle: expectedCollapsed=\(collapsed) actual=\(String(describing: dashboardSidebarIsCollapsed(in: window))) buttons=\(dashboardSidebarToggleButtons(in: window).count)")
        }
        try await waitForSidebar(collapsed: false)
        guard let button = dashboardSidebarToggleButtons(in: window).first else { throw DashboardSidebarSmokeError.failed("Missing native sidebar button") }
        let before = button.convert(button.bounds, to: nil)
        let mode = reducedMotion ? "reduced-motion" : "animated"
        let appearance = dark ? "dark" : "light"
        try await captureNativeWindow(window, to: directory.appendingPathComponent("sidebar-expanded-\(appearance)-\(mode).png"))
        button.performClick(nil)
        try await waitForSidebar(collapsed: true)
        // Capture waits for the compositor after the visibility state settles.
        try await captureNativeWindow(window, to: directory.appendingPathComponent("sidebar-collapsed-\(appearance)-\(mode).png"))
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
        try await captureNativeWindow(window, to: directory.appendingPathComponent("sidebar-reopened-\(appearance)-\(mode).png"))
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
            backdrop.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.37, blue: 0.76, alpha: 1)
            try await captureNativeWindow(window, to: directory.appendingPathComponent("sidebar-cool-backdrop-\(appearance).png"))
        }
        let report: [String: Any] = ["expanded": NSStringFromRect(before), "collapsed": NSStringFromRect(collapsed),
            "reopened": NSStringFromRect(after), "keyboardEquivalent": true, "spaceActivation": true, "reduceMotion": reducedMotion,
            "nativeToggleCount": dashboardSidebarToggleButtons(in: window).count, "defaultToggleCount": systemToggleCount]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("sidebar-toggle-\(appearance)-\(mode).json"))
        print("sidebar-toggle: fixed native position, pointer and keyboard passed; \(appearance) \(mode)")
    }
}

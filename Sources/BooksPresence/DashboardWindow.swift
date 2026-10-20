import AppKit
import Combine

/// One unified window, as Finder, Notes and Mail are on macOS 26: the floating glass sidebar runs
/// to the top edge with the traffic lights on it, and the garden and page run under a transparent
/// title bar with no strip or separator. AppKit keeps the title (Mission Control, the Window
/// menu), dragging, double-click to zoom, full screen and the standard button positions.
@MainActor
final class DashboardWindow: NSWindow {
    private var themeSubscription: AnyCancellable?

    /// The dashboard as the app shows it. Previews and smokes use this too, so they capture the
    /// same chrome the reader sees.
    static func make() -> DashboardWindow {
        let window = DashboardWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Stillleaf"
        window.isReleasedWhenClosed = false
        // Menu-bar (accessory) apps get no full-screen behavior unless a window opts in.
        window.collectionBehavior.insert(.fullScreenPrimary)
        return window
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        // The garden runs under the title bar; the traffic lights and sidebar
        // toggle sit over the floating glass sidebar. Nothing may set the title
        // bar opaque again: an opaque one paints its own strip across both.
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        titlebarSeparatorStyle = .none
        toolbarStyle = .unified
        updateCanvas()
        // Receive on the next main-loop turn: @Published sends before the new
        // revision is installed. Reassigning also invalidates AppKit's backing.
        themeSubscription = ThemeStore.shared.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateCanvas() }
    }

    /// A transparent title bar lets clicks in its band through to the hosted SwiftUI view, which
    /// neither moves nor zooms the window. Nothing interactive lives in that band (the sidebar
    /// toggle is an AppKit toolbar button and keeps its own clicks), so a press there behaves as on
    /// any title bar: drag to move, double-click for the action chosen in Desktop & Dock.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, treatsAsTitlebar(event.locationInWindow) {
            if !isKeyWindow { makeKey() }
            if event.clickCount == 2 { performTitlebarDoubleClick() } else { performDrag(with: event) }
            return
        }
        super.sendEvent(event)
    }

    /// Whether a press at `point` (window coordinates) lands in the title bar band on the page or
    /// sidebar rather than on a control.
    func treatsAsTitlebar(_ point: NSPoint) -> Bool {
        guard !styleMask.contains(.fullScreen), point.y >= contentLayoutRect.maxY, point.y <= frame.height,
              let content = contentView, let themeFrame = content.superview,
              let hit = themeFrame.hitTest(themeFrame.convert(point, from: nil)) else { return false }
        return hit === content || (hit.isDescendant(of: content) && !(hit is NSControl))
    }

    private func performTitlebarDoubleClick() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": if styleMask.contains(.miniaturizable) { performMiniaturize(nil) }
        case "None": break
        default: if styleMask.contains(.resizable) { performZoom(nil) }
        }
    }

    override var contentViewController: NSViewController? {
        didSet { DispatchQueue.main.async { [weak self] in self?.installTitlebarToolbarIfNeeded() } }
    }

    /// SwiftUI lends the hosted view's toolbar (the sidebar toggle) to the window only when built
    /// with the macOS 14 SDK or later. Without a toolbar AppKit draws a 28 pt title bar whose
    /// traffic lights sit left of and above the floating sidebar, so older-SDK builds get an empty
    /// unified toolbar: the same 52 pt band, with the lights on the sidebar.
    private func installTitlebarToolbarIfNeeded() {
        #if !compiler(>=5.9)
        guard toolbar == nil, contentViewController != nil else { return }
        let bar = NSToolbar(identifier: "dashboard-titlebar")
        bar.displayMode = .iconOnly
        bar.allowsUserCustomization = false
        toolbar = bar
        #endif
    }

    private func updateCanvas() {
        if #available(macOS 26.0, *) {
            // The detail view owns its opaque paper. Keep the window behind
            // the system glass sidebar clear so it can sample its backdrop;
            // another app-painted canvas here flattens that material.
            isOpaque = false
            backgroundColor = .clear
            return
        }
        isOpaque = true
        backgroundColor = NSColor(name: nil) { appearance in
            let snapshot = ThemeSnapshot.current()
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return ReadingPalette.nsColor((dark ? snapshot.dark : snapshot.light).canvas)
        }
    }
}

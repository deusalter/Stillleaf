import AppKit

/// The reader's page runs the whole window, under a transparent title bar, so the book and the band
/// above it are one surface with no strip or separator. The renderer keeps its text clear of the band,
/// and in the same place whether the controls are showing or not. The window takes the page's colour too,
/// for the frames before the first paint and for a resize outrunning the web view.
///
/// The title, traffic lights and toolbar follow the page's lightness, so a Night page gets light
/// ones in Light mode. Only the title bar takes that appearance: the web view keeps the system's,
/// because the renderer's System theme reads `prefers-color-scheme` from it.
@MainActor
enum ReaderTitlebar {
    /// Before the renderer reports its page, the System theme's colours: white by day,
    /// true black at night (`appearance.js`).
    static let defaultPage = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    }

    static func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = defaultPage
    }

    /// `appearance` is the renderer's `effectiveAppearance`. A missing or unreadable colour leaves the title bar as it is.
    static func follow(page appearance: [String: Any], in window: NSWindow) {
        guard let color = color(hex: appearance["backgroundColor"] as? String) else { return }
        if window.backgroundColor != color { window.backgroundColor = color }
        let dark = ReaderPanelPalette(appearance: appearance).dark
        titlebarView(of: window)?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// The view holding the title, traffic lights and toolbar.
    static func titlebarView(of window: NSWindow) -> NSView? {
        window.standardWindowButton(.closeButton)?.superview
    }

    static func color(hex: String?) -> NSColor? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// A reader window: the web view runs under the title bar, so presses in the band that land on the page
/// are handed to the window as title bar drags and double-clicks.
@MainActor
final class ReaderWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, treatsAsTitlebar(event.locationInWindow) {
            if !isKeyWindow { makeKey() }
            if event.clickCount == 2 { performTitlebarDoubleClick() } else { performDrag(with: event) }
            return
        }
        super.sendEvent(event)
    }

    /// Whether a press at `point` (window coordinates) lands in the title bar band on the page rather than on a control.
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
}

/// Decides when the reader's controls show. Like Apple Books, they show while the pointer is in the band at the
/// top of the window and fade as soon as it leaves; elsewhere the book has the window to itself. They stay put for
/// an open panel, for VoiceOver and for full keyboard access, where hiding them would hide the only way to them.
@MainActor
final class ReaderChromeVisibility: NSResponder {
    /// Measured from Books: controls stay at 50 pt below the window's top edge and are gone at 70 pt.
    static let band: CGFloat = 60
    private weak var window: NSWindow?
    private var pointerInBand = false
    private var pointerMoved = false
    var hold = false { didSet { if hold != oldValue { update() } } }
    var fullScreen = false { didSet { if fullScreen != oldValue { update() } } }
    /// Whether the controls are showing, including AppKit's own reveal of the toolbar in full screen.
    private(set) var visible = true
    var changed: ((Bool) -> Void)?

    init(window: NSWindow) { self.window = window; super.init() }
    required init?(coder: NSCoder) { fatalError() }

    func track(_ view: NSView) {
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseEntered(with event: NSEvent) { pointer(event) }
    override func mouseExited(with event: NSEvent) { pointerMoved = true; if pointerInBand { pointerInBand = false }; update() }

    private func pointer(_ event: NSEvent) {
        guard let window else { return }
        let inBand = window.frame.height - event.locationInWindow.y <= Self.band
        if inBand == pointerInBand && pointerMoved { return }
        pointerMoved = true; pointerInBand = inBand
        update()
    }

    private var keepsControls: Bool { hold || NSWorkspace.shared.isVoiceOverEnabled || NSApp.isFullKeyboardAccessEnabled }

    private func update() {
        // A newly opened book shows its controls until the pointer first moves, as Books does.
        let show = !pointerMoved || pointerInBand || keepsControls
        guard let window, let bar = ReaderTitlebar.titlebarView(of: window) else { visible = show; changed?(show); return }
        // In full screen AppKit slides the toolbar in and out itself.
        let alpha: CGFloat = fullScreen || show ? 1 : 0
        if bar.alphaValue != alpha {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { bar.alphaValue = alpha }
            else { NSAnimationContext.runAnimationGroup { context in context.duration = 0.18; bar.animator().alphaValue = alpha } }
        }
        if show != visible { visible = show; changed?(show) }
    }
}

import AppKit

/// The reader's title bar takes the page's colour, so the book runs up to the top of the window
/// with no grey strip or separator above it. The page itself stays below the title bar, so the
/// renderer's geometry and pagination are unchanged.
///
/// The title, traffic lights and toolbar follow the page's lightness, so a Night page gets light
/// ones in Light mode. Only the title bar takes that appearance: the web view keeps the system's,
/// because the renderer's System theme reads `prefers-color-scheme` from it.
@MainActor
enum ReaderTitlebar {
    /// Before the renderer reports its page, the System theme's colours: Stillleaf paper by day,
    /// true black at night (`appearance.js`).
    static let defaultPage = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : NSColor(srgbRed: 0xF0 / 255.0, green: 0xF7 / 255.0, blue: 0xF3 / 255.0, alpha: 1)
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

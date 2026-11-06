import AppKit
import BooksPlatform

/// Settings → Data & privacy → Help → Open-source licences, and Stillleaf → Open-Source Licences….
@MainActor
final class ThirdPartyNoticesWindow {
    static let shared = ThirdPartyNoticesWindow()
    private var window: NSWindow?

    func show() {
        let window = self.window ?? Self.make(text: ThirdPartyNotices.text() ?? "The licence notices are missing from this build.")
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func make(text: String) -> NSWindow {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textContainerInset = NSSize(width: 12, height: 12)
            view.string = text
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Open-Source Licences"
        window.contentView = scroll
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

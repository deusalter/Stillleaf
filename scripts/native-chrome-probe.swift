import AppKit
import SwiftUI

struct ProbeView: View {
    var body: some View {
        NavigationSplitView { List { Text("Library") } } detail: { Text("Synthetic content") }
            .toolbar { ToolbarItem { Button("Appearance") {} } }
    }
}

@main struct NativeChromeProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ProbeView())
        window.orderBack(nil)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        print("hosting-toolbar-installed=\(window.toolbar != nil)")
        print("toolbar-items=\(window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? [])")
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = NSView()
            print("genuine-glass=\(type(of: glass))")
        } else { print("glass-runtime=fallback") }
        #else
        print("glass-sdk=fallback")
        #endif
        window.close()
    }
}

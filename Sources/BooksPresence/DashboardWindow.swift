import AppKit
import Combine

/// Keep AppKit's title, traffic lights, dragging and fullscreen behavior while
/// letting its transparent title bar share the dashboard's canvas color.
@MainActor
final class DashboardWindow: NSWindow {
    private var themeSubscription: AnyCancellable?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        updateCanvas()
        // Receive on the next main-loop turn: @Published sends before the new
        // revision is installed. Reassigning also invalidates AppKit's backing.
        themeSubscription = ThemeStore.shared.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateCanvas() }
    }

    private func updateCanvas() {
        backgroundColor = NSColor(name: nil) { appearance in
            let snapshot = ThemeSnapshot.current()
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return ReadingPalette.nsColor((dark ? snapshot.dark : snapshot.light).canvas)
        }
    }
}

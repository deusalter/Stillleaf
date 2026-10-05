import AppKit
import SwiftUI

/// Reports whether the hosting window is on screen and not occluded or
/// minimised, so animations can stop while nobody can see them.
struct WindowVisibility: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.report = { visible in
            DispatchQueue.main.async { if isVisible != visible { isVisible = visible } }
        }
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        var report: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { report?(false); return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.update() })
            }
            update()
        }

        private func update() {
            guard let window else { report?(false); return }
            report?(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

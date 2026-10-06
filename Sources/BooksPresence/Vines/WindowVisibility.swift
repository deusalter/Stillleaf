import AppKit
import SwiftUI

/// Reports whether the hosting window is on screen and not occluded or
/// minimised, so animations can stop while nobody can see them.
struct WindowVisibility: NSViewRepresentable {
    @Binding var isVisible: Bool
    /// True while the user drags the window's edge.
    var isResizing: Binding<Bool>? = nil

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.report = { visible in
            DispatchQueue.main.async { if isVisible != visible { isVisible = visible } }
        }
        probe.reportResizing = { live in
            DispatchQueue.main.async { if let isResizing, isResizing.wrappedValue != live { isResizing.wrappedValue = live } }
        }
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        var report: ((Bool) -> Void)?
        var reportResizing: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { report?(false); return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.update() })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in self?.reportResizing?(true) })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in self?.reportResizing?(false) })
            update()
        }

        private func update() {
            guard let window else { report?(false); return }
            report?(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

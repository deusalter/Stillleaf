import AppKit
import SwiftUI

/// How much of the Quiet UI motion plays: counts, the breathing goal ring, ripples through
/// the garden and the glass parallax. One value decides all of it, so no effect can forget
/// Reduce Motion or Low Power Mode.
enum QuietMotion: Equatable {
    /// Everything moves.
    case full
    /// Low Power Mode or a still garden: the short counts and fills stay, the ambient motion goes.
    case calm
    /// Reduce Motion, and captures: every value appears at its final state.
    case still

    /// Counts and the ring's first fill. They are short and happen once, so they survive Low Power.
    var plays: Bool { self != .still }
    /// The pulse, the light, ripples and parallax: the motion that keeps running or follows the pointer.
    var ambient: Bool { self == .full }

    static func resolve(reduceMotion: Bool, lowPower: Bool, garden: GardenMode, capture: Bool = QuietMotion.isCapture) -> QuietMotion {
        if reduceMotion || capture { return .still }
        if lowPower || garden != .animated { return .calm }
        return .full
    }

    /// Offscreen renders and frozen-time previews must show the settled screen.
    static var isCapture: Bool {
        GardenClock.frozenTime != nil || CommandLine.arguments.contains("--offscreen")
    }
}

extension ThemeStore {
    /// What Quiet UI motion plays now: Reduce Motion stills it, Low Power Mode or a still garden calms it.
    func quietMotion(reduceMotion: Bool) -> QuietMotion {
        QuietMotion.resolve(reduceMotion: reduceMotion, lowPower: lowPowerIsOn, garden: gardenMode)
    }
}

/// The Quiet UI motion level for the current view, following Reduce Motion, Low Power Mode and
/// the garden setting live. Use as `@QuietMotionLevel private var motion`.
@propertyWrapper
struct QuietMotionLevel: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativePreviewReduceMotion) private var previewReduceMotion
    @ObservedObject private var theme = ThemeStore.shared

    init() {}

    var wrappedValue: QuietMotion {
        MainActor.assumeIsolated { theme.quietMotion(reduceMotion: previewReduceMotion ?? reduceMotion) }
    }
}

/// Observes whether the hosting window can be seen at all, so repeating animations are
/// removed while nobody can see them and added again when the window returns.
/// Callbacks arrive on the main queue.
final class WindowVisibilityObserver {
    private var observers: [NSObjectProtocol] = []
    private weak var window: NSWindow?
    private let changed: (Bool) -> Void

    init(changed: @escaping (Bool) -> Void) { self.changed = changed }

    func attach(to window: NSWindow?) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.window = window
        guard let window else { changed(false); return }
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.update()
            })
        }
        update()
    }

    func detach() { attach(to: nil) }

    private func update() {
        guard let window else { changed(false); return }
        changed(window.occlusionState.contains(.visible) && !window.isMiniaturized)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

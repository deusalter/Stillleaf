import AppKit
import SwiftUI

/// A slight depth between the glass panels and the garden behind them: the garden drifts a few
/// points toward the pointer while the glass stays put. Only the garden's position moves, never
/// its drawing, and the glass, its frost and its text are not touched.
enum GardenParallax {
    /// The farthest the garden drifts, in points, when the pointer is at the window's edge.
    static let reach = CGSize(width: 3, height: 2.25)
    static let animation = Animation.easeOut(duration: 0.35)

    /// The drift for a pointer at `unit` (0…1 across the window, top-left origin). The drift is
    /// snapped to whole device pixels, so the garden is crisp wherever it comes to rest.
    static func offset(pointer unit: CGPoint?, scale: CGFloat, motion: QuietMotion) -> CGSize {
        guard motion.ambient, let unit, scale > 0 else { return .zero }
        // Toward zero, so snapping never carries the drift past its reach.
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.towardZero) / scale }
        let x = min(1, max(0, unit.x)), y = min(1, max(0, unit.y))
        return CGSize(width: snap((x - 0.5) * 2 * reach.width), height: snap((y - 0.5) * 2 * reach.height))
    }
}

/// Follows the pointer across the view it backs and reports the garden's drift, only when the
/// snapped drift changes: a few dozen times across a whole window, not once per mouse move.
final class PointerDriftView: NSView {
    var motion = QuietMotion.still
    var drifted: ((CGSize) -> Void)?
    private var last = CGSize.zero

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        report(CGPoint(x: point.x / bounds.width, y: 1 - point.y / bounds.height))
    }

    override func mouseExited(with event: NSEvent) { report(nil) }

    /// Back to rest, as when motion is turned down or the window goes away.
    func rest() { report(nil) }

    func report(_ unit: CGPoint?) {
        let scale = window?.backingScaleFactor ?? 2
        let drift = GardenParallax.offset(pointer: unit, scale: scale, motion: motion)
        guard drift != last else { return }
        last = drift
        drifted?(drift)
    }
}

struct GardenPointer: NSViewRepresentable {
    let motion: QuietMotion
    let drifted: (CGSize) -> Void

    func makeNSView(context: Context) -> PointerDriftView { PointerDriftView(frame: .zero) }

    func updateNSView(_ view: PointerDriftView, context: Context) {
        let wasAmbient = view.motion.ambient
        view.motion = motion
        view.drifted = drifted
        if wasAmbient && !motion.ambient { view.rest() }
    }
}

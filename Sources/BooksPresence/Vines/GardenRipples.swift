import AppKit
import SwiftUI

/// Carries a hover or click on a control to the gardens in the same window, which answer with a
/// ripple through their glyphs. Window-keyed and AppKit-driven, so any control in any window
/// can start one without the garden's owner knowing about it. Used on the main thread only.
final class GardenRippleHub {
    static let shared = GardenRippleHub()
    /// Fewest seconds between two hover ripples in one window, so sweeping across a row of buttons stays calm.
    static let hoverSpacing: CFTimeInterval = 0.18

    private let hosts = NSHashTable<RippleHostView>.weakObjects()
    private let sources = NSHashTable<RippleSourceView>.weakObjects()
    private var lastHover: [ObjectIdentifier: CFTimeInterval] = [:]
    private var monitor: Any?

    func register(_ host: RippleHostView) { hosts.add(host) }
    func unregister(_ host: RippleHostView) { hosts.remove(host) }

    func register(_ source: RippleSourceView) {
        sources.add(source)
        // One click monitor for the process: it only looks at mouse-downs, so it costs nothing at rest.
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let window = event.window { self?.clicked(in: window, at: event.locationInWindow) }
            return event
        }
    }

    func unregister(_ source: RippleSourceView) { sources.remove(source) }

    func hovered(in window: NSWindow, at point: NSPoint, now: CFTimeInterval = CACurrentMediaTime()) {
        let id = ObjectIdentifier(window)
        guard now - (lastHover[id] ?? -.infinity) >= Self.hoverSpacing else { return }
        lastHover[id] = now
        fire(in: window, at: point, strength: 0.5)
    }

    /// A click on a control sends a stronger ripple than a hover does.
    func clicked(in window: NSWindow, at point: NSPoint) {
        guard sources.allObjects.contains(where: { $0.window === window && $0.contains(windowPoint: point) }) else { return }
        fire(in: window, at: point, strength: 1)
    }

    func fire(in window: NSWindow, at point: NSPoint, strength: CGFloat) {
        for host in hosts.allObjects where host.window === window { host.ripple(atWindowPoint: point, strength: strength) }
    }
}

/// Marks a control as a place ripples start from. Draws nothing and takes no clicks.
final class RippleSourceView: NSView {
    private var inside = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { GardenRippleHub.shared.unregister(self) } else { GardenRippleHub.shared.register(self) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard let window else { return }
        GardenRippleHub.shared.hovered(in: window, at: event.locationInWindow)
    }

    func contains(windowPoint point: NSPoint) -> Bool {
        let local = convert(point, from: nil)
        return !visibleRect.isEmpty && visibleRect.contains(local)
    }
}

private struct RippleSource: NSViewRepresentable {
    func makeNSView(context: Context) -> RippleSourceView { RippleSourceView(frame: .zero) }
    func updateNSView(_ view: RippleSourceView, context: Context) {}
}

extension View {
    /// Hovering this control sends a soft ripple through the garden behind the glass, and clicking it a stronger one.
    func gardenRipple() -> some View { background(RippleSource()) }
}

/// A ripple through the garden's glyphs. The grown garden is one image, so a ripple is a layer of
/// bright colour cut to the shape of that image's glyphs and shown only inside a soft ring that
/// grows and fades. The ring is a gradient layer whose stops and opacity are animated by the
/// render server: the app draws nothing while a ripple runs and schedules nothing but one
/// clean-up when it ends.
final class RippleHostView: NSView {
    /// Seconds a ripple takes to cross the garden and fade.
    static let duration: CFTimeInterval = 1.25
    /// How far a ripple spreads, in points.
    static let reach: CGFloat = 420
    /// Half the width of the lit ring, in points.
    static let band: CGFloat = 38
    static let maxRipples = 4
    static let animationKey = "ripple.sweep"

    private let lit = CALayer()
    /// The bright colour, cut to the glyphs.
    private let tint = CALayer()
    private let glyphs = CALayer()
    private let mask = CALayer()
    private var rings: [CAGradientLayer] = []
    private var motion = QuietMotion.still
    private var windowVisible = false
    private var imageID: ObjectIdentifier?
    private var hasImage = false
    private var visibility: WindowVisibilityObserver?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        lit.isHidden = true
        glyphs.contentsGravity = .resize
        tint.mask = glyphs
        lit.addSublayer(tint)
        lit.mask = mask
        layer?.addSublayer(lit)
        visibility = WindowVisibilityObserver { [weak self] visible in self?.setWindowVisible(visible) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { GardenRippleHub.shared.unregister(self) } else { GardenRippleHub.shared.register(self) }
        visibility?.attach(to: window)
    }

    override func layout() {
        super.layout()
        lit.frame = bounds
        mask.frame = bounds
        tint.frame = lit.bounds
        glyphs.frame = tint.bounds
    }

    func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        if !visible { clear() }
    }

    func apply(image: NSImage?, motion: QuietMotion, tint color: NSColor = .white) {
        self.motion = motion
        tint.backgroundColor = color.cgColor
        if let image {
            if imageID != ObjectIdentifier(image) {
                imageID = ObjectIdentifier(image)
                glyphs.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            hasImage = true
        } else {
            hasImage = false
            imageID = nil
            glyphs.contents = nil
        }
        if !motion.ambient || !hasImage { clear() }
    }

    /// Ripples still on screen.
    var activeRipples: Int { rings.count }
    var showsRipple: Bool { !lit.isHidden }

    /// The animation running on the `index`th ripple's ring.
    func rippleAnimation(at index: Int) -> CAAnimation? {
        rings.indices.contains(index) ? rings[index].animation(forKey: Self.animationKey) : nil
    }

    func ripple(atWindowPoint point: NSPoint, strength: CGFloat) {
        guard motion.ambient, windowVisible, hasImage, bounds.width > 0 else { return }
        let local = convert(point, from: nil)
        // Too far outside this garden for the ring to ever reach it.
        guard bounds.insetBy(dx: -Self.reach, dy: -Self.reach).contains(local) else { return }
        let ring = makeRing(at: local, strength: strength, progress: nil)
        add(ring)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.05) { [weak self, weak ring] in
            guard let self, let ring else { return }
            self.finish(ring)
        }
    }

    private func add(_ ring: CAGradientLayer) {
        if rings.count >= Self.maxRipples, let oldest = rings.first { finish(oldest) }
        rings.append(ring)
        mask.addSublayer(ring)
        lit.isHidden = false
    }

    private func finish(_ ring: CAGradientLayer) {
        ring.removeAllAnimations()
        ring.removeFromSuperlayer()
        rings.removeAll { $0 === ring }
        if rings.isEmpty { lit.isHidden = true }
    }

    /// Stops every ripple at once: the window went away, or motion was turned down.
    func clear() {
        rings.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        rings = []
        lit.isHidden = true
    }

    private static let profile: [(offset: Double, alpha: Double)] = [(-1, 0), (-0.5, 0.4), (0, 1), (0.5, 0.4), (1, 0)]

    /// The ring's gradient stops when its crest is `center` of the way to `reach`.
    static func stops(center: Double) -> [NSNumber] {
        let half = Double(band / reach)
        return profile.map { NSNumber(value: min(1, max(0, center + $0.offset * half))) }
    }

    private func makeRing(at point: CGPoint, strength: CGFloat, progress: Double?) -> CAGradientLayer {
        let ring = CAGradientLayer()
        ring.type = .radial
        ring.startPoint = CGPoint(x: 0.5, y: 0.5)
        ring.endPoint = CGPoint(x: 1, y: 1)
        ring.bounds = CGRect(x: 0, y: 0, width: Self.reach * 2, height: Self.reach * 2)
        ring.position = point
        ring.colors = Self.profile.map { CGColor(gray: 1, alpha: CGFloat($0.alpha) * strength) }
        ring.locations = Self.stops(center: progress ?? 0)
        if let progress {
            ring.opacity = Float(1 - progress * 0.7)
            return ring
        }
        let steps = 16
        let crest = CAKeyframeAnimation(keyPath: "locations")
        crest.values = (0...steps).map { Self.stops(center: Double($0) / Double(steps)) }
        crest.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        crest.calculationMode = .linear
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0.85, 0.45, 0]
        fade.keyTimes = [0, 0.3, 0.7, 1]
        let group = CAAnimationGroup()
        group.animations = [crest, fade]
        group.duration = Self.duration
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: Self.animationKey)
        return ring
    }

    /// A ripple frozen part-way (0…1) for previews and captures, which render model values rather than animations.
    func pose(atLocal point: CGPoint, progress: Double, strength: CGFloat) {
        guard hasImage else { return }
        add(makeRing(at: point, strength: strength, progress: progress))
    }

    deinit { visibility?.detach() }
}

struct RippleHost: NSViewRepresentable {
    let image: NSImage?
    let motion: QuietMotion
    /// What the glyphs light up to: pale in the dark, deep in the light.
    let tint: UInt32

    func makeNSView(context: Context) -> RippleHostView { RippleHostView(frame: .zero) }
    func updateNSView(_ view: RippleHostView, context: Context) {
        view.apply(image: image, motion: motion, tint: ReadingPalette.nsColor(tint))
    }
}

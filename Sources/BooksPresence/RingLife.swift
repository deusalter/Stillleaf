import AppKit
import SwiftUI

/// Where the dotted goal ring's dots sit. The arc that draws them and the layers that make
/// them breathe share it, so the glow always sits on the arc's leading edge.
/// Points are in the arc's own coordinates, with y growing downward.
struct RingGeometry: Equatable {
    let size: CGSize
    static let startDegrees = 140.0
    static let sweepDegrees = 260.0
    /// The outer row, then the inner row: dot count, diameter, inset from the outer radius (all at 254 pt wide).
    static let rows: [(count: Int, diameter: Double, inset: Double, trackOpacity: Double, fillOpacity: Double)] = [
        (37, 8, 0, 1, 1), (31, 6, 16, 0.65, 0.7)
    ]

    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.53) }
    var radius: Double { Double(min(size.width * 0.45, size.height * 0.48)) }
    var scale: Double { Double(min(1, size.width / 254)) }

    /// Clockwise angle, in radians from the +x axis, of a position along the arc (0…1).
    func angle(at position: Double) -> Double { (Self.startDegrees + position * Self.sweepDegrees) * .pi / 180 }

    func dot(row: Int, index: Int) -> (center: CGPoint, diameter: Double) {
        let spec = Self.rows[row]
        let distance = radius - spec.inset * scale
        let a = angle(at: Double(index) / Double(spec.count - 1))
        return (CGPoint(x: Double(center.x) + cos(a) * distance, y: Double(center.y) + sin(a) * distance), spec.diameter * scale)
    }

    /// Between the two rows, where the filled part of the arc ends.
    func leadingPoint(_ fraction: Double) -> CGPoint {
        let a = angle(at: min(1, max(0, fraction)))
        let distance = radius - 8 * scale
        return CGPoint(x: Double(center.x) + cos(a) * distance, y: Double(center.y) + sin(a) * distance)
    }
}

/// The goal ring's life, as Core Animation layers over the drawn arc. The leading dot breathes on
/// a 4 s cycle, and while a book is being read a light runs along the filled dots every 8 s. Both
/// are repeating animations on the render server, so they ask nothing of the app between frames.
/// They are removed while the window cannot be seen, under Low Power Mode and Reduce Motion.
final class RingLifeView: NSView {
    static let pulseKeys = ["ring.pulse.opacity", "ring.pulse.scale"]
    static let lightKeys = ["ring.light.sweep", "ring.light.fade"]
    /// Seconds for the glow to swell and ebb once.
    static let pulsePeriod: CFTimeInterval = 4
    static let lightPeriod: CFTimeInterval = 8
    /// Seconds the light takes to cross the filled dots, at the start of each period.
    static let lightSweep: CFTimeInterval = 1.6

    private let ambient = CALayer()
    private let glow = CAGradientLayer()
    private let lit = CALayer()
    private let sweep = CAGradientLayer()
    private var progress = 0.0
    private var reading = false
    private var motion = QuietMotion.still
    private var accent = NSColor.systemGreen
    private var glint = NSColor.white
    private var enterDelay: TimeInterval = 0
    private var entered = false
    private var windowVisible = false
    private var drawnKey = ""
    private var visibility: WindowVisibilityObserver?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ambient.isHidden = true
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        // Conic from the layer's centre: a narrow band of opacity that the mask rotates around the ring.
        sweep.type = .conic
        sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
        sweep.endPoint = CGPoint(x: 0.5, y: 1)
        let half = 0.045
        sweep.colors = [0, 0, 1, 0, 0].map { CGColor(gray: 1, alpha: $0) }
        sweep.locations = [0, 0.5 - half, 0.5, 0.5 + half, 1].map { NSNumber(value: $0) }
        lit.mask = sweep
        ambient.addSublayer(lit)
        ambient.addSublayer(glow)
        layer?.addSublayer(ambient)
        visibility = WindowVisibilityObserver { [weak self] visible in self?.setWindowVisible(visible) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility?.attach(to: window)
    }

    override func layout() {
        super.layout()
        rebuild()
        // The animations wait for a size; start them once there is one.
        if shouldBreathe && ambient.isHidden { refresh() }
    }

    /// Whether the animations may run. Follows the window; self-checks set it directly.
    func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        refresh()
    }

    func apply(progress: Double, reading: Bool, motion: QuietMotion, accent: NSColor, glint: NSColor, enterDelay: TimeInterval) {
        let rebuilds = progress != self.progress || accent != self.accent || glint != self.glint
        let restarts = reading != self.reading || motion != self.motion || progress != self.progress
        self.progress = progress
        self.reading = reading
        self.motion = motion
        self.accent = accent
        self.glint = glint
        if !entered { self.enterDelay = max(self.enterDelay, enterDelay) }
        if rebuilds { rebuild() }
        if restarts { refresh() }
    }

    /// The keys of every animation currently running on the ring's layers.
    var runningAnimations: [String] {
        (glow.animationKeys() ?? []) + (lit.animationKeys() ?? []) + (sweep.animationKeys() ?? [])
    }

    var showsAmbientLayers: Bool { !ambient.isHidden }

    func layerAnimation(forKey key: String) -> CAAnimation? {
        glow.animation(forKey: key) ?? lit.animation(forKey: key) ?? sweep.animation(forKey: key)
    }

    private var shouldBreathe: Bool { motion.ambient && windowVisible && progress > 0.01 && bounds.width > 0 }
    private var shouldShine: Bool { shouldBreathe && reading }

    private func refresh() {
        stopAnimations()
        guard shouldBreathe else { ambient.isHidden = true; return }
        ambient.isHidden = false
        if !entered {
            entered = true
            if enterDelay > 0 {
                // The first fill finishes before the glow appears.
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.6
                fade.beginTime = CACurrentMediaTime() + enterDelay
                fade.fillMode = .backwards
                ambient.add(fade, forKey: "ring.enter")
            }
        }
        let half = Self.pulsePeriod / 2
        func pulse(_ path: String, _ from: Double, _ to: Double, _ key: String) {
            let animation = CABasicAnimation(keyPath: path)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = half
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(animation, forKey: key)
        }
        pulse("opacity", 0.35, 0.75, Self.pulseKeys[0])
        pulse("transform.scale", 0.8, 1.25, Self.pulseKeys[1])
        guard shouldShine else { lit.isHidden = true; return }
        lit.isHidden = false
        let start = CACurrentMediaTime()
        let rotate = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotate.values = [Self.rotation(toArcPosition: 0), Self.rotation(toArcPosition: progress), Self.rotation(toArcPosition: progress)]
        rotate.keyTimes = [0, NSNumber(value: Self.lightSweep / Self.lightPeriod), 1]
        rotate.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        let end = Self.lightSweep / Self.lightPeriod
        fade.values = [0, 1, 1, 0, 0]
        fade.keyTimes = [0, 0.02, NSNumber(value: end - 0.02), NSNumber(value: end), 1]
        for (animation, layer, key) in [(rotate, sweep as CALayer, Self.lightKeys[0]), (fade, lit, Self.lightKeys[1])] {
            animation.duration = Self.lightPeriod
            animation.repeatCount = .infinity
            animation.beginTime = start
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: key)
        }
    }

    private func stopAnimations() {
        glow.removeAllAnimations()
        lit.removeAllAnimations()
        sweep.removeAllAnimations()
        ambient.removeAnimation(forKey: "ring.enter")
    }

    /// Rotation of the conic mask that puts its band over a position along the whole arc
    /// (0 = the first dot, 1 = the last). The band rests at the bottom of the layer, a quarter
    /// turn clockwise from 3 o'clock, and rotation z is counterclockwise-positive.
    static func rotation(toArcPosition position: Double) -> Double {
        let degrees = RingGeometry.startDegrees + min(1, max(0, position)) * RingGeometry.sweepDegrees
        return (90 - degrees) * .pi / 180
    }

    /// Positions the layers and redraws the lit dots; only when the ring's size, progress or colour changed.
    private func rebuild() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(size.width)x\(size.height)@\(scale)/\(progress)/\(accent.hashValue)/\(glint.hashValue)"
        guard key != drawnKey else { return }
        drawnKey = key
        let geometry = RingGeometry(size: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        ambient.frame = bounds
        let diameter: CGFloat = size.width >= 200 ? 26 : 20
        glow.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let lead = geometry.leadingPoint(progress)
        glow.position = CGPoint(x: lead.x, y: size.height - lead.y)
        // The mockup's glow sprite: bright at the dot, falling away quickly.
        glow.colors = [0.95, 0.45, 0.12, 0].map { accent.withAlphaComponent($0).cgColor }
        glow.locations = [0, 0.18, 0.5, 1]
        lit.frame = bounds
        lit.contentsScale = scale
        lit.contents = Self.litDots(geometry: geometry, progress: progress, color: glint, scale: scale)
        // The mask turns about the ring's centre, which sits a little below the middle of the layer.
        let reach = max(size.width, size.height) * 2
        sweep.bounds = CGRect(x: 0, y: 0, width: reach, height: reach)
        sweep.position = CGPoint(x: geometry.center.x, y: size.height - geometry.center.y)
        sweep.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(Self.rotation(toArcPosition: 0))))
    }

    /// The colour of the light that runs along the filled dots: near white in the dark, the accent lightened in the light.
    static func glintColor(accent: UInt32, dark: Bool) -> UInt32 {
        dark ? 0xEFFFF8 : VinePalette.mix(accent, 0xFFFFFF, 0.55)
    }

    /// Just the filled dots, drawn in `color`, with the arc's own smooth leading edge.
    static func litDots(geometry: RingGeometry, progress: Double, color: NSColor, scale: CGFloat) -> CGImage? {
        let size = geometry.size
        guard let context = CGContext(data: nil, width: max(1, Int(size.width * scale)), height: max(1, Int(size.height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let fraction = min(1, max(0, progress))
        for (row, spec) in RingGeometry.rows.enumerated() {
            for index in 0..<spec.count {
                let coverage = min(1, max(0, fraction * Double(spec.count) - Double(index)))
                guard coverage > 0 else { continue }
                let dot = geometry.dot(row: row, index: index)
                context.setFillColor(color.withAlphaComponent(CGFloat(coverage * spec.fillOpacity)).cgColor)
                let r = dot.diameter / 2
                context.fillEllipse(in: CGRect(x: Double(dot.center.x) - r, y: Double(size.height) - Double(dot.center.y) - r, width: dot.diameter, height: dot.diameter))
            }
        }
        return context.makeImage()
    }

    /// A still pose for previews and captures, which render model values rather than running animations.
    func pose(pulse: Double, lightAt position: Double?) {
        stopAnimations()
        ambient.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.opacity = Float(0.35 + 0.4 * pulse)
        glow.setAffineTransform(CGAffineTransform(scaleX: 0.8 + 0.45 * pulse, y: 0.8 + 0.45 * pulse))
        if let position {
            lit.isHidden = false
            lit.opacity = 1
            sweep.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(Self.rotation(toArcPosition: position * progress))))
        } else {
            lit.isHidden = true
        }
        CATransaction.commit()
    }

    deinit { visibility?.detach() }
}

struct RingLife: NSViewRepresentable {
    let progress: Double
    let reading: Bool
    let motion: QuietMotion
    let accent: UInt32
    let glint: UInt32
    var enterDelay: TimeInterval = 0

    func makeNSView(context: Context) -> RingLifeView { RingLifeView(frame: .zero) }

    func updateNSView(_ view: RingLifeView, context: Context) {
        view.apply(progress: progress, reading: reading, motion: motion, accent: ReadingPalette.nsColor(accent),
                   glint: ReadingPalette.nsColor(glint), enterDelay: enterDelay)
    }
}

/// The dotted goal ring: it fills dot by dot the first time it appears, then breathes.
/// Changes afterwards animate with `change`, as before; Reduce Motion shows the ring filled.
@MainActor
struct GoalArc: View {
    let progress: Double
    /// Names the ring across appearances; see `QuietLedger`.
    let key: String
    let reading: Bool
    let change: Animation
    @QuietMotionLevel private var motion
    @Environment(\.colorScheme) private var colorScheme
    @State private var shown: Double?

    static let fillDuration: TimeInterval = 1.1
    static let fill = Animation.easeOut(duration: fillDuration)

    var body: some View {
        let start = QuietLedger.shared.start(key, value: Self.token(progress))
        let first = Self.firstProgress(progress, start: start, motion: motion)
        ZStack {
            DottedReadingArc(progress: shown ?? first)
            RingLife(progress: progress, reading: reading, motion: motion, accent: accent.base,
                     glint: accent.glint, enterDelay: first == progress ? 0 : Self.fillDuration)
                .allowsHitTesting(false)
        }
        .onAppear { appear() }
        .onChange(of: progress) { value in
            QuietLedger.shared.record(key, value: Self.token(value))
            withAnimation(motion.plays ? change : nil) { shown = value }
        }
    }

    private var accent: (base: UInt32, glint: UInt32) {
        let snapshot = ThemeSnapshot.current()
        let dark = colorScheme == .dark
        let base = (dark ? snapshot.dark : snapshot.light).accent
        return (base, RingLifeView.glintColor(accent: base, dark: dark))
    }

    private func appear() {
        let token = Self.token(progress)
        let first = Self.firstProgress(progress, start: QuietLedger.shared.start(key, value: token), motion: motion)
        QuietLedger.shared.record(key, value: token)
        guard first != progress, shown == nil else { shown = progress; return }
        withAnimation(Self.fill) { shown = progress }
    }

    static func token(_ progress: Double) -> String { String(format: "%.4f", progress) }

    /// Where the first frame's fill starts from.
    static func firstProgress(_ progress: Double, start: QuietLedger.Start, motion: QuietMotion) -> Double {
        guard motion.plays else { return progress }
        switch start {
        case .settled: return progress
        case .fromZero: return 0
        case .from(let old): return Double(old) ?? progress
        }
    }
}

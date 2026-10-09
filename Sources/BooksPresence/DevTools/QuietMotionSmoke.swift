import AppKit
import SwiftUI

/// Checks for the Quiet UI motion: one policy for Reduce Motion, Low Power Mode and the garden
/// setting, and animations that stop when the window hides or motion is turned down. They look at
/// the Core Animation layers directly, so no window is shown and nothing has to run for a second
/// to prove that something stopped.
@MainActor
func checkQuietMotion() throws {
    let checks: [(String, () throws -> Void)] = [
        ("motion level follows Reduce Motion, Low Power Mode, the garden setting and captures", checkMotionLevels),
        ("counts start at zero once, roll when the value changes and replay only after a while away", checkCountingPolicy),
        ("Reduce Motion shows counts, the ring and the garden at rest", checkReduceMotionIsInstant),
        ("the ring's pulse and light are repeating compositor animations that stop with the window, Low Power and Reading", checkRingAnimationsStop),
        ("ripples run on the render server, end by themselves and stop with the window", checkRippleLifecycle),
        ("parallax stays within its reach, snaps to pixels and rests without full motion", checkParallax),
    ]
    // Run every check so one failure does not hide the rest.
    var failures: [String] = []
    for (name, check) in checks {
        do { try check() } catch { failures.append("\(name): \(error)") }
    }
    guard failures.isEmpty else { throw QuietCheckError.failed("Quiet UI checks failed:\n  " + failures.joined(separator: "\n  ")) }
    print("ui-smoke: Quiet UI counts, ring, ripples and parallax follow Reduce Motion and Low Power, and their animations stop with the window")
}

private enum QuietCheckError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { return message }; return "" }
}

private func fail(_ message: String) -> QuietCheckError { .failed(message) }

private func descendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
    root.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + root.subviews.flatMap { descendants(of: $0, as: type) }
}

private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

// MARK: Policy

@MainActor private func checkMotionLevels() throws {
    func level(reduce: Bool = false, lowPower: Bool = false, garden: GardenMode = .animated, capture: Bool = false) -> QuietMotion {
        QuietMotion.resolve(reduceMotion: reduce, lowPower: lowPower, garden: garden, capture: capture)
    }
    guard level() == .full else { throw fail("Nothing is turned down but the level is not full") }
    guard level(reduce: true) == .still, level(reduce: true, lowPower: true, garden: .off) == .still else { throw fail("Reduce Motion does not make everything instant") }
    guard level(lowPower: true) == .calm else { throw fail("Low Power Mode does not calm the ambient motion") }
    guard level(garden: .still) == .calm, level(garden: .off) == .calm else { throw fail("A still or hidden garden keeps ambient motion") }
    guard level(capture: true) == .still else { throw fail("Captures are not settled") }
    guard QuietMotion.full.plays, QuietMotion.full.ambient, QuietMotion.calm.plays, !QuietMotion.calm.ambient,
          !QuietMotion.still.plays, !QuietMotion.still.ambient else { throw fail("The tiers play the wrong effects") }

    // The theme store feeds the same policy, and follows Low Power Mode live.
    let defaults = UserDefaults(suiteName: "stillleaf-quiet-smoke-\(UUID().uuidString)")!
    var lowPower = false
    let center = NotificationCenter()
    let store = ThemeStore(defaults: defaults, lowPower: LowPowerSource(isEnabled: { lowPower }, center: center))
    let settled = QuietMotion.isCapture
    guard store.quietMotion(reduceMotion: false) == (settled ? .still : .full) else { throw fail("The theme store resolves the wrong level") }
    guard store.quietMotion(reduceMotion: true) == .still else { throw fail("The theme store ignores Reduce Motion") }
    lowPower = true
    center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    guard store.quietMotion(reduceMotion: false) == (settled ? .still : .calm) else { throw fail("The theme store ignores Low Power Mode") }
}

@MainActor private func checkCountingPolicy() throws {
    for (text, zero) in [("19", "0"), ("1h 05m", "0h 0m"), ("1,234 pages", "0 pages"), ("12/340", "0/0"), ("3 days", "0 days"), ("Allowed", "Allowed"), ("2.5 min", "0 min")] {
        guard CountingText.zeroed(text) == zero else { throw fail("\"\(text)\" starts from \"\(CountingText.zeroed(text))\", not \"\(zero)\"") }
    }
    guard CountingText.number(in: "1,234 pages") == 1234, CountingText.number(in: "1h 05m") == 1, CountingText.number(in: "none") == 0 else {
        throw fail("The leading number is read wrongly")
    }
    var clock = Date(timeIntervalSinceReferenceDate: 1_000)
    let ledger = QuietLedger()
    ledger.now = { clock }
    guard ledger.start("pages", value: "19") == .fromZero else { throw fail("A new number does not count up") }
    ledger.record("pages", value: "19")
    guard ledger.start("pages", value: "19") == .settled else { throw fail("A number replays when its screen returns at once") }
    guard ledger.start("pages", value: "24") == .from("19") else { throw fail("A changed number does not roll from the old one") }
    clock.addTimeInterval(QuietLedger.freshness + 1)
    guard ledger.start("pages", value: "19") == .fromZero else { throw fail("A number never counts up again after a long time away") }
    guard ledger.start("minutes", value: "19") == .fromZero else { throw fail("Numbers share a memory") }
    for motion in [QuietMotion.full, .calm] {
        guard CountingText.firstText("19", start: .fromZero, motion: motion) == "0",
              CountingText.firstText("19", start: .settled, motion: motion) == "19",
              CountingText.firstText("24", start: .from("19"), motion: motion) == "19" else { throw fail("The first frame is wrong at \(motion)") }
    }
    for start in [QuietLedger.Start.fromZero, .settled, .from("19")] {
        guard CountingText.firstText("24", start: start, motion: .still) == "24" else { throw fail("Reduce Motion counts: \(start)") }
    }
    // A value that changes every second rolls once, not every second.
    guard CountingText.rolls(sinceLastChange: 10), !CountingText.rolls(sinceLastChange: 1) else { throw fail("Rolls are not spaced out") }
    guard GoalArc.firstProgress(0.6, start: .fromZero, motion: .full) == 0, GoalArc.firstProgress(0.6, start: .fromZero, motion: .calm) == 0,
          GoalArc.firstProgress(0.6, start: .fromZero, motion: .still) == 0.6, GoalArc.firstProgress(0.6, start: .settled, motion: .full) == 0.6,
          GoalArc.firstProgress(0.6, start: .from("0.2000"), motion: .full) == 0.2 else { throw fail("The ring's first fill starts from the wrong place") }
}

// MARK: Reduce Motion

/// Hosts a real goal ring and returns the animation layers' state, with the window treated as visible.
@MainActor private func hostedRing(reduceMotion: Bool, _ inspect: (RingLifeView) throws -> Void) throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = GoalArc(progress: 0.6, key: "smoke.ring.\(UUID().uuidString)", reading: true, change: .default)
        .frame(width: 254, height: 250)
        .environment(\.nativePreviewReduceMotion, reduceMotion)
    let hosting = NSHostingView(rootView: root)
    window.contentView = hosting
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    defer { window.contentView = nil; window.close() }
    hosting.layoutSubtreeIfNeeded()
    spin(0.25)
    hosting.layoutSubtreeIfNeeded()
    guard let ring = descendants(of: hosting, as: RingLifeView.self).first else { throw fail("The goal ring has no animation layers") }
    ring.setWindowVisible(true)
    try inspect(ring)
}

@MainActor private func checkReduceMotionIsInstant() throws {
    try hostedRing(reduceMotion: true) { ring in
        guard ring.runningAnimations.isEmpty, !ring.showsAmbientLayers else {
            throw fail("Reduce Motion left the ring animating: \(ring.runningAnimations)")
        }
    }
    // The same ring does breathe when nothing is turned down, so the check above is not vacuous.
    let expected = ThemeStore.shared.quietMotion(reduceMotion: false)
    try hostedRing(reduceMotion: false) { ring in
        let keys = Set(ring.runningAnimations)
        if expected.ambient {
            guard keys == Set(RingLifeView.pulseKeys + RingLifeView.lightKeys) else { throw fail("A reading ring does not breathe at full motion: \(keys)") }
        } else {
            guard keys.isEmpty else { throw fail("The ring animates at \(expected): \(keys)") }
        }
    }
    // Garden effects: nothing ripples and nothing drifts.
    let host = RippleHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    host.apply(image: rippleImage(), motion: .still)
    host.setWindowVisible(true)
    host.ripple(atWindowPoint: NSPoint(x: 100, y: 100), strength: 1)
    guard host.activeRipples == 0, !host.showsRipple else { throw fail("Reduce Motion still ripples") }
    guard GardenParallax.offset(pointer: CGPoint(x: 0, y: 1), scale: 2, motion: .still) == .zero else { throw fail("Reduce Motion still drifts the garden") }
    let pointer = PointerDriftView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    var drifts = 0
    pointer.drifted = { _ in drifts += 1 }
    pointer.motion = .still
    for step in 0...40 { pointer.report(CGPoint(x: Double(step) / 40, y: 0.3)) }
    guard drifts == 0 else { throw fail("The pointer moved the garden \(drifts) times under Reduce Motion") }
}

// MARK: Animations stopping

@MainActor private func checkRingAnimationsStop() throws {
    let all = Set(RingLifeView.pulseKeys + RingLifeView.lightKeys)
    let view = RingLifeView(frame: NSRect(x: 0, y: 0, width: 254, height: 250))
    func apply(progress: Double = 0.6, reading: Bool = true, motion: QuietMotion = .full) {
        view.apply(progress: progress, reading: reading, motion: motion, accent: .systemGreen, glint: .white, enterDelay: 0)
        view.layoutSubtreeIfNeeded()
    }
    view.needsLayout = true
    apply()
    guard view.runningAnimations.isEmpty, !view.showsAmbientLayers else { throw fail("A ring that is not in a visible window animates") }
    view.setWindowVisible(true)
    guard Set(view.runningAnimations) == all, view.showsAmbientLayers else { throw fail("A visible reading ring does not pulse and shine: \(view.runningAnimations)") }

    // Both are repeating Core Animation animations: the render server runs them between app frames.
    for key in RingLifeView.pulseKeys {
        guard let animation = view.layerAnimation(forKey: key) as? CABasicAnimation, animation.repeatCount == .infinity, animation.autoreverses,
              animation.duration == RingLifeView.pulsePeriod / 2 else { throw fail("\(key) is not a 4 s autoreversing loop") }
    }
    for key in RingLifeView.lightKeys {
        guard let animation = view.layerAnimation(forKey: key) as? CAKeyframeAnimation, animation.repeatCount == .infinity,
              animation.duration == RingLifeView.lightPeriod else { throw fail("\(key) is not an 8 s loop") }
    }

    view.setWindowVisible(false)
    guard view.runningAnimations.isEmpty, !view.showsAmbientLayers else { throw fail("Hiding the window left animations running: \(view.runningAnimations)") }
    view.setWindowVisible(true)
    guard Set(view.runningAnimations) == all else { throw fail("Showing the window did not bring the animations back") }

    apply(reading: false)
    guard Set(view.runningAnimations) == Set(RingLifeView.pulseKeys) else { throw fail("The light runs when nothing is being read: \(view.runningAnimations)") }
    apply(reading: true)
    guard Set(view.runningAnimations) == all else { throw fail("Reading again does not bring the light back") }
    apply(motion: .calm)
    guard view.runningAnimations.isEmpty, !view.showsAmbientLayers else { throw fail("Low Power Mode left the ring animating") }
    apply(motion: .still)
    guard view.runningAnimations.isEmpty else { throw fail("Reduce Motion left the ring animating") }
    apply(motion: .full)
    guard Set(view.runningAnimations) == all else { throw fail("Turning motion back up does not restart the ring") }
    apply(progress: 0)
    guard view.runningAnimations.isEmpty else { throw fail("An empty ring breathes") }
    apply(progress: 0.6)

    // The window going away stops the animations, whoever removes it.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView?.addSubview(view)
    view.setWindowVisible(true)
    guard !view.runningAnimations.isEmpty else { throw fail("The ring did not animate in its window") }
    view.removeFromSuperview()
    guard view.runningAnimations.isEmpty, !view.showsAmbientLayers else { throw fail("Removing the ring from its window left animations running") }
}

@MainActor private func rippleImage() -> NSImage {
    GardenModel.bitmap(size: CGSize(width: 400, height: 300), scale: 1) {
        NSColor.systemGreen.setFill()
        NSBezierPath(rect: NSRect(x: 40, y: 40, width: 300, height: 200)).fill()
    }
}

@MainActor private func checkRippleLifecycle() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = RippleHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    window.contentView?.addSubview(host)
    let image = rippleImage()
    let centre = host.convert(NSPoint(x: 200, y: 150), to: nil)

    host.apply(image: image, motion: .full)
    host.ripple(atWindowPoint: centre, strength: 1)
    guard host.activeRipples == 0 else { throw fail("A ripple started in a window nobody can see") }
    host.setWindowVisible(true)
    host.ripple(atWindowPoint: centre, strength: 1)
    guard host.activeRipples == 1, host.showsRipple, let animation = host.rippleAnimation(at: 0) as? CAAnimationGroup,
          animation.duration == RippleHostView.duration, animation.repeatCount == 0 else { throw fail("A ripple is not one animation on the render server") }
    // Every set of gradient stops it passes through is valid: in range and in order.
    for step in 0...20 {
        let stops = RippleHostView.stops(center: Double(step) / 20).map(\.doubleValue)
        guard stops.allSatisfy({ (0...1).contains($0) }), zip(stops, stops.dropFirst()).allSatisfy({ $0 <= $1 }) else { throw fail("The ring's stops are out of order at step \(step)") }
    }
    spin(RippleHostView.duration + 0.4)
    guard host.activeRipples == 0, !host.showsRipple else { throw fail("A finished ripple stayed on screen") }

    // Hiding the window ends a ripple in flight at once.
    host.ripple(atWindowPoint: centre, strength: 0.5)
    guard host.activeRipples == 1 else { throw fail("A second ripple did not start") }
    host.setWindowVisible(false)
    guard host.activeRipples == 0, !host.showsRipple else { throw fail("Hiding the window left a ripple running") }
    host.setWindowVisible(true)

    // Motion turned down ends them too, and a burst is capped.
    for _ in 0..<7 { host.ripple(atWindowPoint: centre, strength: 1) }
    guard host.activeRipples == RippleHostView.maxRipples else { throw fail("Ripples are not capped: \(host.activeRipples)") }
    host.apply(image: image, motion: .calm)
    guard host.activeRipples == 0, !host.showsRipple else { throw fail("Low Power Mode left ripples running") }
    host.ripple(atWindowPoint: centre, strength: 1)
    guard host.activeRipples == 0 else { throw fail("A ripple started under Low Power Mode") }
    host.apply(image: nil, motion: .full)
    host.ripple(atWindowPoint: centre, strength: 1)
    guard host.activeRipples == 0 else { throw fail("A ripple started over a garden that is still growing") }
    host.apply(image: image, motion: .full)

    // Hover ripples are routed by window, spaced out, and sent only where the pointer is over a control.
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    let bystander = RippleHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    other.contentView?.addSubview(bystander)
    bystander.apply(image: image, motion: .full)
    bystander.setWindowVisible(true)
    let hub = GardenRippleHub.shared
    host.clear()
    // Spacing is judged against the clock the caller passes, far from any real hover time.
    let start = CACurrentMediaTime() + 1_000
    guard hub.hovered(in: window, at: centre, now: start) else { throw fail("A hover did not ripple") }
    guard !hub.hovered(in: window, at: centre, now: start + GardenRippleHub.hoverSpacing / 2) else { throw fail("Hover ripples are not spaced out") }
    guard hub.hovered(in: window, at: centre, now: start + GardenRippleHub.hoverSpacing * 2) else { throw fail("A later hover did not ripple") }
    guard host.activeRipples >= 1, bystander.activeRipples == 0 else {
        throw fail("Hover ripples are not kept to their window (\(host.activeRipples) here, \(bystander.activeRipples) elsewhere)")
    }
    let button = RippleSourceView(frame: NSRect(x: 150, y: 120, width: 100, height: 60))
    window.contentView?.addSubview(button)
    defer { button.removeFromSuperview() }
    let away = host.convert(NSPoint(x: 10, y: 10), to: nil)
    guard !hub.clicked(in: window, at: away) else { throw fail("A click away from any control rippled (at \(away), control at \(button.convert(button.bounds, to: nil)))") }
    guard hub.clicked(in: window, at: centre) else { throw fail("A click on a control did not ripple (at \(centre), control at \(button.convert(button.bounds, to: nil)))") }
    host.clear()
}

// MARK: Parallax

@MainActor private func checkParallax() throws {
    let reach = GardenParallax.reach
    guard GardenParallax.offset(pointer: CGPoint(x: 0.5, y: 0.5), scale: 2, motion: .full) == .zero else { throw fail("The garden drifts with the pointer at the centre") }
    guard GardenParallax.offset(pointer: nil, scale: 2, motion: .full) == .zero else { throw fail("The garden does not return to rest when the pointer leaves") }
    for scale in [CGFloat(1), 2] {
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            for y in stride(from: 0.0, through: 1.0, by: 0.05) {
                let drift = GardenParallax.offset(pointer: CGPoint(x: x, y: y), scale: scale, motion: .full)
                guard abs(drift.width) <= reach.width, abs(drift.height) <= reach.height else { throw fail("The garden drifts \(drift), past its reach") }
                guard (drift.width * scale).rounded() == drift.width * scale, (drift.height * scale).rounded() == drift.height * scale else {
                    throw fail("A drift of \(drift) rests between device pixels at \(scale)x")
                }
            }
        }
    }
    guard GardenParallax.offset(pointer: CGPoint(x: 1, y: 0), scale: 2, motion: .full).width > 0,
          GardenParallax.offset(pointer: CGPoint(x: 0, y: 0), scale: 2, motion: .full).width < 0 else { throw fail("The garden drifts away from the pointer") }
    for motion in [QuietMotion.calm, .still] {
        guard GardenParallax.offset(pointer: CGPoint(x: 0, y: 0), scale: 2, motion: motion) == .zero else { throw fail("The garden drifts at \(motion)") }
    }

    // A whole sweep across the window reports a handful of drifts, not one per mouse move, and none at rest.
    let view = PointerDriftView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var drifts: [CGSize] = []
    view.drifted = { drifts.append($0) }
    view.motion = .full
    for step in 0...400 { view.report(CGPoint(x: Double(step) / 400, y: 0.5)) }
    guard drifts.count <= 14, drifts.count >= 2 else { throw fail("A sweep reported \(drifts.count) drifts") }
    view.report(nil)
    guard drifts.last == .zero else { throw fail("The pointer leaving did not bring the garden to rest") }
    let before = drifts.count
    view.report(nil)
    guard drifts.count == before else { throw fail("A garden at rest was told to move again") }
    view.report(CGPoint(x: 0, y: 0))
    view.motion = .calm
    view.rest()
    guard drifts.last == .zero else { throw fail("Turning motion down did not bring the garden to rest") }
}

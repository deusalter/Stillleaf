import AppKit
import SwiftUI

/// Finishing a book. A mint seal settles onto the cover's corner, one soft ring of light leaves it,
/// and the garden answers with a single ripple from the cover. Nothing waits for it: the prompt
/// beside it is drawn and usable from its first frame, and the moment plays once per completion.
///
/// | `QuietMotion` | What plays |
/// |---|---|
/// | full | the seal settles, the ring, a garden ripple |
/// | calm (Low Power, a still garden) | the seal settles, the ring |
/// | still (Reduce Motion, captures) | the seal at rest |
///
/// Timeline, from the prompt appearing: 0.4 s pause while the card or sheet arrives; the seal
/// fades in and settles from 92 % over 0.36 s, ease-out, no overshoot; the ring grows to 1.9×
/// while it fades over 0.8 s; the ripple is Core Animation's (1.25 s). Nothing runs after 1.7 s.
enum FinishMoment {
    static let delay: TimeInterval = 0.4
    static let duration: TimeInterval = 0.8
    /// The share of `duration` the seal takes to settle (0.36 s).
    static let settleShare = 0.45
    static let settleScale = 0.92
    static let ringScale = 1.9
    static let ringOpacity = 0.45
    /// How the prompt makes room on Today, and gives it back.
    static let arrive = Animation.easeInOut(duration: 0.3)
    /// Rides the same glide: arriving, the prompt stays clear while the sections below make room and
    /// fades in over the second half, so it is never drawn over them; leaving, it is gone within the
    /// first third, before they close up. No delay, so the glide starts on the frame the finish lands.
    static let promptTransition = AnyTransition.asymmetric(
        insertion: .modifier(active: LateOpacity(progress: 0, from: 0.45), identity: LateOpacity(progress: 1, from: 0.45)),
        removal: .modifier(active: LateOpacity(progress: 0, from: 0.7), identity: LateOpacity(progress: 1, from: 0.7)))

    /// Opacity that stays at zero until `from` of the way through its animation.
    struct LateOpacity: ViewModifier, Animatable {
        var progress: Double
        let from: Double
        var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }
        func body(content: Content) -> some View { content.opacity(max(0, (progress - from) / (1 - from))) }
    }

    struct Plan: Equatable {
        var settles: Bool
        var ring: Bool
        var ripple: Bool
    }

    static func plan(for motion: QuietMotion) -> Plan {
        switch motion {
        case .full: return Plan(settles: true, ring: true, ripple: true)
        case .calm: return Plan(settles: true, ring: true, ripple: false)
        case .still: return Plan(settles: false, ring: false, ripple: false)
        }
    }

    /// The seal at `progress` (0…1 of `duration`): eased in over the first `settleShare`, then at rest.
    static func seal(_ progress: Double) -> (opacity: Double, scale: Double) {
        let t = easeOut(min(1, max(0, progress / settleShare)))
        return (t, 1 - (1 - settleScale) * (1 - t))
    }

    /// The ring at `progress`: nothing at rest (0 and 1), otherwise growing and fading together.
    static func ring(_ progress: Double) -> (opacity: Double, scale: Double) {
        guard progress > 0, progress < 1 else { return (0, 1) }
        let t = easeOut(progress)
        return (ringOpacity * (1 - t), 1 + (ringScale - 1) * t)
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}

/// Use only in the pending completion prompt. The owner consumes the saved completion event
/// before returning true; remounting a view cannot replay it.
struct CompletionCelebrationBadge: View {
    /// Previews pin the motion level; the app follows Reduce Motion, Low Power and the garden.
    var motionOverride: QuietMotion?
    let eventID: String
    let claimCelebration: @MainActor () -> Bool
    @QuietMotionLevel private var liveMotion
    /// 0 → 1 over `FinishMoment.duration`; 1 is at rest.
    @State private var progress: Double = 1
    @State private var ringPlays = true
    /// The event this view last asked the model for, and the one it won and is playing.
    @State private var attempted: String?
    @State private var claimed: String?
    @State private var ripple = FinishRippleAnchor.Trigger()

    private var motion: QuietMotion { motionOverride ?? liveMotion }

    var body: some View {
        FinishSeal(progress: progress, ring: ringPlays)
            .background(FinishRippleAnchor(trigger: ripple))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            // Claim and hide the seal before the first frame is drawn, so it never shows at rest and blinks out.
            .onAppear { claim() }
            .task(id: eventID) { await play() }
            .onChange(of: motion) { level in if level == .still { rest() } }
            .onDisappear { rest() }
    }

    /// Consumes the event even when still: returning to Today or changing a setting never replays it.
    @MainActor private func claim() {
        guard attempted != eventID else { return }
        attempted = eventID
        let plan = FinishMoment.plan(for: motion)
        guard claimCelebration(), plan.settles else { return }
        claimed = eventID
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { progress = 0; ringPlays = plan.ring }
    }

    @MainActor private func play() async {
        // A new completion while this view stays on screen arrives here without an appearance.
        claim()
        guard claimed == eventID else { rest(); return }
        let plan = FinishMoment.plan(for: motion)
        do { try await Task.sleep(nanoseconds: UInt64(FinishMoment.delay * 1_000_000_000)) } catch { rest(); return }
        guard FinishMoment.plan(for: motion).settles else { rest(); return }
        withAnimation(.linear(duration: FinishMoment.duration)) { progress = 1 }
        if plan.ripple { ripple.fire() }
    }

    private func rest() {
        claimed = nil
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { progress = 1 }
    }
}

/// The seal and its ring at one point of the moment. SwiftUI interpolates `progress`; the eased
/// curves come from `FinishMoment`, so one state change drives both.
private struct FinishSeal: View, Animatable {
    var progress: Double
    let ring: Bool
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let seal = FinishMoment.seal(progress)
        let halo = FinishMoment.ring(progress)
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(ReadingPalette.accent)
            .background(Circle().fill(ReadingPalette.canvas).padding(1.5))
            .background {
                if ring && halo.opacity > 0 {
                    Circle().stroke(ReadingPalette.accent, lineWidth: 1.5)
                        .scaleEffect(halo.scale)
                        .opacity(halo.opacity)
                }
            }
            .scaleEffect(seal.scale)
            .opacity(seal.opacity)
    }
}

/// Where the garden's ripple starts: the seal itself, or for a sheet (which has no garden), the
/// dashboard behind it, from where the sheet hangs. `GardenRippleHub` skips gardens that are
/// still, hidden or out of reach.
struct FinishRippleAnchor: NSViewRepresentable {
    final class Trigger {
        fileprivate weak var view: AnchorView?
        func fire() { view?.fire() }
    }

    let trigger: Trigger

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        trigger.view = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) { trigger.view = view }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func fire() {
            guard let window else { return }
            if let parent = window.sheetParent {
                let centre = NSPoint(x: window.frame.midX, y: window.frame.midY)
                GardenRippleHub.shared.fire(in: parent, at: parent.convertPoint(fromScreen: centre), strength: 1)
            } else {
                GardenRippleHub.shared.fire(in: window, at: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil), strength: 1)
            }
        }
    }
}

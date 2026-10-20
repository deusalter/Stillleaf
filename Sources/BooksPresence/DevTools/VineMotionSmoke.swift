import SwiftUI

private enum VineMotionSmokeError: Error { case failed(String) }

/// Checks that the small vine views follow the garden motion setting and stop
/// scheduling frames when nothing is changing.
@MainActor
func checkVineMotionModes() throws {
    func fail(_ message: String) -> Error { VineMotionSmokeError.failed(message) }

    // The finish moment follows the one Quiet UI policy: Reduce Motion stills it, Low Power Mode
    // and a still garden keep only the seal and ring, and nothing in it outlasts its timeline.
    let defaults = UserDefaults(suiteName: "stillleaf-finish-smoke-\(UUID().uuidString)")!
    let store = ThemeStore(defaults: defaults)
    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    for garden in [GardenMode.off, .still, .animated] {
        store.select(garden: garden)
        let still = FinishMoment.plan(for: QuietMotion.resolve(reduceMotion: true, lowPower: lowPower, garden: garden, capture: false))
        guard still == FinishMoment.Plan(settles: false, ring: false, ripple: false) else { throw fail("Reduce Motion still moves the finish moment") }
        let plan = FinishMoment.plan(for: QuietMotion.resolve(reduceMotion: false, lowPower: lowPower, garden: garden, capture: false))
        guard plan.settles, plan.ring, plan.ripple == (garden == .animated && !lowPower) else {
            throw fail("The finish moment plays wrongly for a \(garden) garden: \(plan)")
        }
    }
    guard FinishMoment.plan(for: .still) == FinishMoment.Plan(settles: false, ring: false, ripple: false) else { throw fail("Captures move the finish moment") }
    guard FinishMoment.delay + FinishMoment.duration <= 1.25 else { throw fail("The finish moment runs longer than 1.25 s") }
    // At rest (0 before it starts, 1 after) the ring is gone and the seal is fully drawn at its own size.
    guard FinishMoment.ring(0).opacity == 0, FinishMoment.ring(1).opacity == 0, FinishMoment.seal(1) == (1, 1),
          FinishMoment.seal(0).opacity == 0, FinishMoment.ring(0.5).opacity > 0 else { throw fail("The finish moment does not come to rest") }
    // No overshoot: the seal only grows, the ring only grows and fades.
    let samples = stride(from: 0.01, to: 1.0, by: 0.02).map { ($0, FinishMoment.seal($0), FinishMoment.ring($0)) }
    guard samples.allSatisfy({ $0.1.scale <= 1 && $0.1.opacity <= 1 }),
          zip(samples, samples.dropFirst()).allSatisfy({ $1.1.scale >= $0.1.scale && $1.2.scale >= $0.2.scale && $1.2.opacity <= $0.2.opacity }) else {
        throw fail("The finish moment overshoots or reverses")
    }

    // The seedling pauses through the hold and never ticks past its cycle's animated parts.
    let ticks = VineSeedling.ticks(from: 0, to: VineSeedling.cycle * 3)
    let held = ticks.filter { ($0.truncatingRemainder(dividingBy: VineSeedling.cycle)) > VineSeedling.revealEnd + 0.06
        && ($0.truncatingRemainder(dividingBy: VineSeedling.cycle)) < VineSeedling.cycle - VineSeedling.fade - 0.06 }
    guard held.isEmpty else { throw fail("The seedling ticked \(held.count) times while holding") }
    guard ticks.count < Int(VineSeedling.cycle * 3 * 20 * 0.7) else { throw fail("The seedling still ticks at 20 fps through its hold: \(ticks.count)") }
    guard zip(ticks, ticks.dropFirst()).allSatisfy({ $1 - $0 <= VineSeedling.hold + 0.1 }) else { throw fail("The seedling timeline stalls") }
    // The last revealing tick leaves every glyph fully shown for the hold.
    guard VineSeedling.revealEnd < VineSeedling.cycle - VineSeedling.fade else { throw fail("The seedling's reveal runs into its fade") }
}

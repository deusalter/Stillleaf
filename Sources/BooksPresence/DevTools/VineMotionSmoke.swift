import SwiftUI

private enum VineMotionSmokeError: Error { case failed(String) }

/// Checks that the small vine views follow the garden motion setting and stop
/// scheduling frames when nothing is changing.
@MainActor
func checkVineMotionModes() throws {
    func fail(_ message: String) -> Error { VineMotionSmokeError.failed(message) }

    // The completion burst reads the effective mode, not the raw setting.
    let defaults = UserDefaults(suiteName: "stillleaf-burst-smoke-\(UUID().uuidString)")!
    let store = ThemeStore(defaults: defaults)
    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    store.select(garden: .off)
    for reduce in [false, true] {
        guard CompletionCelebrationBadge.burstPresentation(theme: store, reduceMotion: reduce) == .none else { throw fail("An Off garden still bursts") }
    }
    store.select(garden: .still)
    for reduce in [false, true] {
        guard CompletionCelebrationBadge.burstPresentation(theme: store, reduceMotion: reduce) == .still else { throw fail("A Still garden does not burst as a still flourish") }
    }
    store.select(garden: .animated)
    guard CompletionCelebrationBadge.burstPresentation(theme: store, reduceMotion: false) == (lowPower ? .still : .animated) else { throw fail("An Animated garden bursts wrongly") }
    guard CompletionCelebrationBadge.burstPresentation(theme: store, reduceMotion: true) == .still else { throw fail("Reduce Motion still animates the burst") }
    guard VineBurst.duration(for: .none) == 0, VineBurst.duration(for: .still) < VineBurst.duration(for: .animated) else { throw fail("Burst durations are wrong") }

    // The burst's timeline ends by itself once the burst has faded.
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let burstTicks = Array(VineBurst.Schedule(start: start).entries(from: start, mode: .normal))
    guard let last = burstTicks.last, last.timeIntervalSince(start) >= VineBurst.duration(for: .animated) - 0.1,
          last.timeIntervalSince(start) <= VineBurst.duration(for: .animated) + 0.1, burstTicks.count < 200 else {
        throw fail("The burst timeline does not end when the burst does: \(burstTicks.count) ticks")
    }

    // Growing the burst's field happens on the main thread at the celebration, at the badge's real size.
    let badge = CGSize(width: 220, height: 140)
    let centre = CGRect(x: badge.width / 2 - 16, y: badge.height / 2 - 16, width: 32, height: 32)
    var slowest = 0.0
    for seed in 0..<20 as Range<UInt32> {
        let began = DispatchTime.now().uptimeNanoseconds
        _ = VineBurst.field(size: badge, around: centre, seed: seed)
        slowest = max(slowest, Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
    }
    print(String(format: "ui-smoke: completion burst field grows in at most %.2f ms on the main thread (20 seeds)", slowest))

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

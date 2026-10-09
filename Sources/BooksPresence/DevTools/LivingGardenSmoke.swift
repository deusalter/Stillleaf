import AppKit
import SwiftUI

/// Checks for the living garden: its growth model, its layers, and what it costs to run.
/// Offscreen only: layers are built without a window and stepped on a virtual clock.

private enum LivingCheckError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { return message }; return "" }
}

private func fail(_ message: String) -> LivingCheckError { .failed(message) }

/// The dashboard's and the menu panel's gardens, at the sizes the app gives them.
@MainActor
private enum LivingFixture {
    static let day = "2026-10-09"
    static let dashboard = CGSize(width: 1060, height: 760)
    static let clearing: CGFloat = 114

    static var dashboardLayout: GardenLayout {
        GardenLayout(size: dashboard, clearingHeight: clearing, seed: GardenSeed.daily("dashboard", day: day), living: true, fireflies: 8)
    }

    static var panelLayouts: [GardenLayout] {
        let height: CGFloat = 560
        var trellis = MenuPanelGarden.trellis(day: day)
        trellis.size = CGSize(width: 350, height: height)
        let sideHeight = height - 2 * CGFloat(MenuPanelGarden.trellisBand) * CGFloat(GardenModel.cellHeight)
        return [trellis] + [MenuPanelGarden.Side.leading, .trailing].map { side in
            var layout = MenuPanelGarden.side(side, day: day)
            layout.size = CGSize(width: MenuPanelGarden.sideWidth, height: sideHeight)
            return layout
        }
    }

    /// A garden grown to completion, as it is when the living starts.
    static func grown(_ layout: GardenLayout, mode: GardenMode = .animated) -> GardenModel {
        let previous = GardenClock.frozenTime
        GardenClock.frozenTime = 6
        defer { GardenClock.frozenTime = previous }
        let model = GardenModel()
        model.configure(layout: layout, mode: mode, now: 0)
        return model
    }

    static func palette(dark: Bool) -> VinePalette {
        let snapshot = ThemeSnapshot.current()
        return VinePalette.make(dark ? snapshot.dark : snapshot.light, dark: dark)
    }

    static func view(for model: GardenModel, dark: Bool = true, scale: CGFloat = 2, active: Bool = true, itself: Bool = false,
                     frost: FrostRegions? = nil, frozenAt: Double? = nil) -> LivingGardenView {
        let size = model.layout?.size ?? .zero
        let view = LivingGardenView(frame: NSRect(origin: .zero, size: size))
        view.drivesItself = itself
        view.apply(model: model, palette: palette(dark: dark), dark: dark, scale: scale, active: active, frost: frost, frostOffset: 0, frozenAt: frozenAt)
        return view
    }
}

// MARK: - Correctness

@MainActor
func checkLivingGarden() throws {
    let checks: [(String, () throws -> Void)] = [
        ("the same seed lives the same life", checkLivingDeterministic),
        ("density holds steady while shoots grow and old branches wither", checkLivingDensity),
        ("a long absence is caught up in a bounded step", checkLivingCatchUp),
        ("withering runs from tip to stem, and petals shed from blooms", checkWitherAndPetals),
        ("fireflies keep to free space and blink on 3 to 7 s cycles", checkFireflies),
        ("wind crosses the garden and then rests off-screen", checkWind),
        ("the layers move on the render server and drop away when hidden", checkLivingLayers),
        ("Still, Off and a layout that does not ask never live", checkLivingOptOut),
        ("a render at a fixed moment is still, and keeps fireflies out of glass", checkLivingFrozen),
    ]
    var failures: [String] = []
    for (name, check) in checks {
        do { try check() } catch { failures.append("\(name): \(error)") }
    }
    guard failures.isEmpty else { throw LivingCheckError.failed("Living garden checks failed:\n  " + failures.joined(separator: "\n  ")) }
    print("ui-smoke: the living garden grows, withers, sways, sheds petals and drifts fireflies on the render server, and pauses when hidden")
}

@MainActor private func livingGarden(seed: UInt32 = 5, size: CGSize = CGSize(width: 700, height: 520)) -> LivingGarden {
    let layout = GardenLayout(size: size, clearingHeight: 80, seed: seed, living: true)
    let model = LivingFixture.grown(layout)
    model.beginLiving()
    return model.living!
}

@MainActor private func signature(_ garden: LivingGarden) -> [Int: String] {
    garden.field.cells.mapValues { "\($0.glyph)\($0.kind.rawValue)\($0.branch)" }
}

@MainActor private func checkLivingDeterministic() throws {
    var a = livingGarden(), b = livingGarden(), c = livingGarden(seed: 6)
    let ca = a.advance(to: 900), cb = b.advance(to: 900)
    _ = c.advance(to: 900)
    guard signature(a) == signature(b), ca.born.count == cb.born.count, ca.petals.count == cb.petals.count else {
        throw fail("Two gardens with one seed diverged")
    }
    guard signature(a) != signature(c) else { throw fail("Two seeds lived the same life") }
    // Advancing in pieces is the same life as advancing at once.
    var d = livingGarden()
    for end in stride(from: 100.0, through: 900, by: 100) { _ = d.advance(to: end) }
    guard signature(d) == signature(a) else { throw fail("Advancing in steps changed the garden") }
}

@MainActor private func checkLivingDensity() throws {
    var garden = livingGarden()
    let cap = garden.cap, initial = Set(garden.field.cells.keys)
    var born = 0, withered = 0, low = cap, high = cap
    let clearing = 80.0
    for end in stride(from: 600.0, through: 3 * 3600, by: 600) {
        let changes = garden.advance(to: end)
        born += changes.born.count; withered += changes.withered.count
        low = min(low, garden.field.cells.count); high = max(high, garden.field.cells.count)
        for cell in garden.field.cells.values where Double(cell.y) * garden.field.cellHeight < clearing {
            throw fail("A shoot grew into the header clearing at row \(cell.y)")
        }
    }
    guard born > 150, withered > 150 else { throw fail("Three hours brought \(born) new cells and \(withered) withered ones") }
    guard Double(low) > Double(cap) * 0.6, Double(high) < Double(cap) * 1.3 else {
        throw fail("Density drifted from \(cap) to between \(low) and \(high) cells")
    }
    let kept = initial.intersection(garden.field.cells.keys).count
    guard kept < initial.count else { throw fail("Nothing the garden grew with ever withered") }
    guard garden.field.cells.values.contains(where: { $0.kind == .stem }), garden.field.cells.values.contains(where: { $0.kind == .bloom }) else {
        throw fail("The garden lost its stems or its blooms")
    }
}

@MainActor private func checkLivingCatchUp() throws {
    var garden = livingGarden()
    let began = DispatchTime.now().uptimeNanoseconds
    _ = garden.advance(to: 10 * 3600)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
    guard garden.time == 10 * 3600 else { throw fail("The clock stopped at \(garden.time)") }
    guard ms < 2000 else { throw fail("Catching up ten hours took \(ms) ms") }
    // After the catch-up the garden still grows and withers on schedule.
    let more = garden.advance(to: 10 * 3600 + 300)
    guard !more.born.isEmpty else { throw fail("The garden stopped growing after a catch-up") }
}

@MainActor private func checkWitherAndPetals() throws {
    var garden = livingGarden()
    var changes = LivingGarden.Changes()
    for end in stride(from: 300.0, through: 7200, by: 300) {
        let step = garden.advance(to: end)
        changes.withered += step.withered
        changes.petals += step.petals
        if changes.withered.count > 60 && changes.petals.count > 40 { break }
    }
    guard !changes.withered.isEmpty else { throw fail("Nothing withered") }
    // Within one branch's withering, cells nearer the tip (newer) start first, and it ends within the span.
    let groups = Dictionary(grouping: changes.withered) { $0.event }
    guard let group = groups.values.max(by: { $0.count < $1.count }), group.count > 5 else { throw fail("No branch withered in one piece") }
    let ordered = group.sorted { $0.at < $1.at }
    guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.cell.seq >= $1.cell.seq || $0.at == $1.at }) else {
        throw fail("A branch did not wither from its newest cell back to its oldest")
    }
    guard let first = ordered.first, let last = ordered.last, last.at - first.at <= LivingGarden.witherSpan + 0.01 else {
        throw fail("A branch took longer than \(LivingGarden.witherSpan) s to wither")
    }
    guard !changes.petals.isEmpty else { throw fail("No petal fell") }
    for petal in changes.petals {
        guard petal.alpha(age: 0) == 0, petal.alpha(age: petal.life) == 0, petal.alpha(age: petal.life / 2) > 0.3 else {
            throw fail("A petal does not fade in and out")
        }
        guard petal.position(age: petal.life).y > petal.position(age: 0).y else { throw fail("A petal rose instead of falling") }
    }
    let gaps = zip(changes.petals, changes.petals.dropFirst()).map { $1.at - $0.at }
    let mean = gaps.reduce(0, +) / Double(max(1, gaps.count))
    guard mean > 5, mean < 16 else { throw fail("Petals fell every \(mean) s on average, not about every 9 s") }
}

@MainActor private func checkFireflies() throws {
    let size = CGSize(width: 800, height: 600)
    let blocked = CGRect(x: 250, y: 150, width: 300, height: 300)
    let free: (CGPoint) -> Bool = { p in p.x > 4 && p.y > 90 && p.x < size.width - 4 && p.y < size.height - 4 && !blocked.contains(p) }
    for dark in [true, false] {
        var made = 0
        for index in 0..<8 {
            guard let track = FireflyTrack.make(index: index, seed: 9, size: size, dark: dark, isFree: free) else { continue }
            made += 1
            for t in stride(from: 0.0, through: 2 * track.duration, by: 0.7) {
                let p = track.position(at: t)
                guard free(p) || free(track.position(at: t + 0.01)) else { throw fail("A firefly drifted to \(p), out of free space") }
                let blink = track.blink(at: t)
                guard blink >= 0, blink <= 1 else { throw fail("A blink of \(blink) is outside 0…1") }
            }
            let cycle = 2 * Double.pi / track.omega
            guard cycle >= 2.9, cycle <= 7.1 else { throw fail("A blink cycle of \(cycle) s is not 3 to 7 s") }
            guard track.position(at: 0) == track.points[0], track.position(at: 2 * track.duration) == track.points[0] else {
                throw fail("A firefly's path does not loop")
            }
        }
        guard made == 8 else { throw fail("Only \(made) of 8 \(dark ? "fireflies" : "pollen motes") found room") }
    }
    guard FireflyTrack.make(index: 0, seed: 9, size: size, dark: true, isFree: { _ in false }) == nil else { throw fail("A firefly started where nothing is free") }
}

@MainActor private func checkWind() throws {
    for width in [350.0, 1060.0, 26.0] {
        let wind = GardenWind(width: width)
        guard wind.period >= 10, wind.crossing < wind.period, wind.bandWidth >= 150 else { throw fail("Wind of a \(width) pt garden is mis-sized: \(wind)") }
        guard wind.centre(at: 0) < 0, wind.centre(at: wind.crossing - 0.001) > width - 1,
              wind.centre(at: wind.crossing + 0.1) > width, wind.centre(at: wind.period + 0.001) < 0 else {
            throw fail("The band does not cross the \(width) pt garden and rest outside it")
        }
        guard wind.strength(at: wind.centre(at: wind.period * 0.9), centre: wind.centre(at: wind.period * 0.9)) == 1,
              wind.strength(at: -2000, centre: 0) == 0 else { throw fail("Wind strength is not 1 inside the band and 0 outside it") }
        guard wind.centre(at: wind.crossing * 0.5) > 0, wind.centre(at: wind.crossing * 0.5) < width else { throw fail("The band is not over the garden mid-crossing") }
    }
}

@MainActor private func checkLivingLayers() throws {
    let model = LivingFixture.grown(LivingFixture.dashboardLayout)
    let view = LivingFixture.view(for: model, itself: true)
    var summary = view.summary
    guard summary.tiles > 4, summary.fireflies == 8, summary.windAnimations == 2, summary.hasTimer else {
        throw fail("A running garden is missing layers or its timer: \(summary)")
    }
    guard let breathe = view.breathingMask?.animation(forKey: LivingGardenView.breatheKey) as? CABasicAnimation, breathe.duration == 16 else {
        throw fail("The garden stopped breathing on the render server")
    }
    for layer in view.fireflyLayers {
        guard layer.animation(forKey: LivingGardenView.flightKey) is CAKeyframeAnimation,
              layer.sublayers?.first?.animation(forKey: LivingGardenView.blinkKey) is CAKeyframeAnimation else {
            throw fail("A firefly is not animated by the render server")
        }
    }
    // Tiles are pre-rendered images, never draw callbacks.
    guard view.tileLayers.allSatisfy({ $0.delegate == nil }) else { throw fail("A tile layer draws itself") }
    // Growth: stepping the clock lights up shoots, heads and fading cells without redrawing everything.
    var layersSeen = 0
    for second in stride(from: 1.5, through: 120, by: 1.5) {
        view.step(simTime: second)
        layersSeen = max(layersSeen, view.summary.pending + view.summary.heads)
    }
    guard layersSeen > 0 else { throw fail("Two minutes passed without a shoot growing") }
    // Hidden: nothing but the settled tiles is left, and nothing is scheduled.
    view.stop()
    summary = view.summary
    guard summary.windAnimations == 0, summary.fireflies == 0, !summary.hasTimer, summary.pending == 0, summary.transients == 0, summary.heads == 0,
          view.breathingMask == nil, !view.isRunning else { throw fail("A hidden garden kept animating: \(summary)") }
    // Back in view: it catches up in one step, starts again, and keeps the shoots it grew.
    view.start(simTime: 3600)
    summary = view.summary
    guard summary.windAnimations == 2, summary.fireflies == 8, view.isRunning, summary.pending == 0 else {
        throw fail("A returning garden did not resume cleanly: \(summary)")
    }
    view.stop()
}

@MainActor private func checkLivingOptOut() throws {
    let layout = LivingFixture.dashboardLayout
    for mode in [GardenMode.still, .off] {
        let model = LivingFixture.grown(layout, mode: mode)
        model.beginLiving()
        guard model.living == nil else { throw fail("A \(mode.label) garden began to live") }
    }
    var quiet = layout
    quiet.living = false
    let model = LivingFixture.grown(quiet)
    model.beginLiving()
    guard model.living == nil else { throw fail("A garden that does not ask to live began to") }
    // A garden still growing cannot live yet.
    let growing = GardenModel()
    growing.configure(layout: layout, mode: .animated, now: 0)
    growing.beginLiving()
    guard growing.living == nil else { throw fail("A garden began to live before it finished growing") }
    // Reduce Motion and Low Power turn Animated into Still.
    let store = ThemeStore(defaults: UserDefaults(suiteName: "stillleaf-living-smoke-\(UUID().uuidString)")!)
    guard store.effectiveGardenMode(reduceMotion: true) == .still else { throw fail("Reduce Motion still lets the garden live") }
}

@MainActor private func checkLivingFrozen() throws {
    let model = LivingFixture.grown(LivingFixture.dashboardLayout)
    let frost = FrostRegions()
    let glass = GlassRegion(frame: CGRect(x: 120, y: 200, width: 800, height: 300), cornerRadius: 20)
    frost.rects = [glass]
    let view = LivingFixture.view(for: model, frost: frost, frozenAt: 400)
    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
    let summary = view.summary
    guard !summary.hasTimer, !view.isRunning, summary.windAnimations == 0, view.breathingMask == nil else { throw fail("A frozen render still animates: \(summary)") }
    guard summary.fireflies == 8 else { throw fail("A frozen render has \(summary.fireflies) fireflies, not 8") }
    let height = LivingFixture.dashboard.height
    for layer in view.fireflyLayers {
        guard layer.animation(forKey: LivingGardenView.flightKey) == nil else { throw fail("A frozen firefly is animated") }
        let point = CGPoint(x: layer.position.x, y: height - layer.position.y)
        guard !glass.frame.contains(point) else { throw fail("A firefly sits behind glass at \(point)") }
        guard point.y >= LivingFixture.clearing else { throw fail("A firefly sits in the header clearing at \(point)") }
    }
}

// MARK: - Frame budget

/// What the living garden may cost the main thread, measured on a virtual clock so it takes
/// seconds, not minutes, and does not depend on how long the machine idles. The target is the
/// plan's idle CPU of 1.5% or less per window; a single step must also fit well inside a frame.
struct GardenFrameBudget {
    /// Idle main-thread CPU per window, as a fraction of one core.
    static let idleCPU = 0.015
    /// A growth step's main-thread time: half a 60 Hz frame at the 95th percentile.
    static let stepP95Ms = 8.0
    /// Its worst case, two frames, for a shared CI runner's scheduling.
    static let stepMaxMs = 33.0
    /// One-off costs, when a window opens, comes back into view, or the glass refreshes its blur.
    static let buildMs = 400.0
    static let resumeMs = 150.0
    static let frostMs = 200.0
    /// Virtual seconds measured per garden.
    static let seconds = 900.0
}

private func threadCPUMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }

struct GardenBudgetReport: Codable {
    var name: String
    var cells: Int
    var seconds: Double
    var steps: Int
    var idleCPUPercent: Double
    var stepP95Ms: Double
    var stepMaxMs: Double
    var buildMs: Double
    var resumeMs: Double
    var frostMs: Double
    var passed: Bool
    var failures: [String]
}

/// One measurement of a window's gardens, ticking together as they do in the window.
private struct BudgetTrial {
    var cells = 0, steps = 0
    var totalMs = 0.0, build = 0.0, resume = 0.0, frost = 0.0
    var costs: [Double] = []

    var p95: Double {
        let sorted = costs.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }
    var worst: Double { costs.max() ?? 0 }
}

@MainActor
private func measureBudget(_ layouts: [GardenLayout]) -> BudgetTrial {
    var trial = BudgetTrial()
    for layout in layouts {
        let model = LivingFixture.grown(layout)
        trial.cells += model.field.cells.count
        var began = threadCPUMs()
        let view = LivingFixture.view(for: model)
        trial.build = max(trial.build, threadCPUMs() - began)
        var t = 0.0
        // Warm up past the first shoot, so tiles and glyph bitmaps are cached as in a window open a while.
        while t < 60 { t += LivingGarden.tick; view.step(simTime: t) }
        let end = t + GardenFrameBudget.seconds
        while t < end {
            t += LivingGarden.tick
            began = threadCPUMs()
            view.step(simTime: t)
            CATransaction.flush()
            let cost = threadCPUMs() - began
            trial.costs.append(cost); trial.totalMs += cost; trial.steps += 1
        }
        view.stop()
        began = threadCPUMs()
        view.start(simTime: t + 1500)
        CATransaction.flush()
        trial.resume = max(trial.resume, threadCPUMs() - began)
        view.stop()
        began = threadCPUMs()
        _ = model.frostedRaster(palette: LivingFixture.palette(dark: true), scale: 2)
        trial.frost = max(trial.frost, threadCPUMs() - began)
    }
    return trial
}

/// Measures every garden of the dashboard and the menu panel and fails when one is over budget.
/// Each window is measured three times and judged on its best trial per metric: a shared CI
/// runner only ever adds time, so the minimum is the cost of the code, and a real regression
/// raises every trial. `--garden-frame-budget [report.json]`.
@MainActor
func runGardenFrameBudget(report output: URL? = nil) throws {
    let panel = LivingFixture.panelLayouts
    let windows: [(String, [GardenLayout])] = [("dashboard", [LivingFixture.dashboardLayout]), ("menu panel", panel)]
    var reports: [GardenBudgetReport] = []
    for (name, layouts) in windows {
        let trials = (0..<3).map { _ in measureBudget(layouts) }
        let cpu = (trials.map(\.totalMs).min() ?? 0) / 1000 / GardenFrameBudget.seconds
        let p95 = trials.map(\.p95).min() ?? 0, worst = trials.map(\.worst).min() ?? 0
        let build = trials.map(\.build).min() ?? 0, resume = trials.map(\.resume).min() ?? 0, frost = trials.map(\.frost).min() ?? 0
        var failures: [String] = []
        if cpu > GardenFrameBudget.idleCPU { failures.append(String(format: "idle CPU %.2f%% is over %.1f%%", cpu * 100, GardenFrameBudget.idleCPU * 100)) }
        if p95 > GardenFrameBudget.stepP95Ms { failures.append(String(format: "step p95 %.2f ms is over %.0f ms", p95, GardenFrameBudget.stepP95Ms)) }
        if worst > GardenFrameBudget.stepMaxMs { failures.append(String(format: "worst step %.2f ms is over %.0f ms", worst, GardenFrameBudget.stepMaxMs)) }
        if build > GardenFrameBudget.buildMs { failures.append(String(format: "first build %.0f ms is over %.0f ms", build, GardenFrameBudget.buildMs)) }
        if resume > GardenFrameBudget.resumeMs { failures.append(String(format: "resume %.0f ms is over %.0f ms", resume, GardenFrameBudget.resumeMs)) }
        if frost > GardenFrameBudget.frostMs { failures.append(String(format: "frost refresh %.0f ms is over %.0f ms", frost, GardenFrameBudget.frostMs)) }
        reports.append(GardenBudgetReport(name: name, cells: trials[0].cells, seconds: GardenFrameBudget.seconds, steps: trials[0].steps,
                                          idleCPUPercent: cpu * 100, stepP95Ms: p95, stepMaxMs: worst, buildMs: build, resumeMs: resume,
                                          frostMs: frost, passed: failures.isEmpty, failures: failures))
    }
    for r in reports {
        print(String(format: "garden-budget: %@ — %d cells, idle %.3f%% CPU (limit %.1f%%), step p95 %.2f ms / max %.2f ms, first build %.0f ms, resume %.0f ms, frost %.0f ms (best of 3): %@",
                     r.name, r.cells, r.idleCPUPercent, GardenFrameBudget.idleCPU * 100, r.stepP95Ms, r.stepMaxMs, r.buildMs, r.resumeMs, r.frostMs, r.passed ? "within budget" : "OVER BUDGET"))
    }
    if let output {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(to: output)
    }
    let failures = reports.flatMap { report in report.failures.map { "\(report.name): \($0)" } }
    guard failures.isEmpty else { throw LivingCheckError.failed("Garden frame budget exceeded:\n  " + failures.joined(separator: "\n  ")) }
}

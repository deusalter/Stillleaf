import AppKit
import Combine
import SwiftUI
import BooksCore

/// Checks for the garden's render efficiency and frost accuracy: the compositor-driven
/// breathing, bitmap scales, raster invalidation, frost corner radii and the header clearing.
@MainActor
func checkGardenRenderEfficiency() throws {
    let checks: [(String, () throws -> Void)] = [
        ("breathing runs as a compositor animation only while asked to", checkBreathingLayer),
        ("raster and frost bitmaps follow the given scale and the frost stays small", checkBitmapScales),
        ("a replant with identical step and cell counts invalidates the raster", checkReplantInvalidatesRaster),
        ("the frost mask matches each panel's corner radius", checkFrostMaskCorners),
        ("glass surfaces publish their own corner radius", checkGlassPublishesRadius),
        ("frost regions publish only meaningful changes", checkFrostRegionsCoalesce),
        ("spores stay out of the header clearing and avoided rectangles", checkSporesStayClear),
    ]
    // Run every check so one failure does not hide the rest.
    var failures: [String] = []
    for (name, check) in checks {
        do { try check() } catch { failures.append("\(name): \(error)") }
    }
    guard failures.isEmpty else { throw GardenCheckError.failed("Garden render checks failed:\n  " + failures.joined(separator: "\n  ")) }
    print("ui-smoke: garden breathes on the compositor, sizes bitmaps by window scale, frosts with each panel's corners, and keeps spores clear")
}

private enum GardenCheckError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { return message }; return "" }
}

private func fail(_ message: String) -> GardenCheckError { .failed(message) }

@MainActor private func checkBreathingLayer() throws {
    let size = NSSize(width: 400, height: 300)
    let view = GardenStillView(frame: NSRect(origin: .zero, size: size))
    let image = NSImage(size: size)
    view.apply(image: image, breathing: false)
    guard view.layer?.mask == nil else { throw fail("A still garden kept a breathing mask") }
    view.apply(image: image, breathing: true)
    guard let mask = view.breathingMask, let animation = mask.animation(forKey: GardenStillView.breatheKey) as? CABasicAnimation else {
        throw fail("Breathing did not start a Core Animation animation")
    }
    guard animation.duration == 16, animation.autoreverses, animation.repeatCount == .infinity else {
        throw fail("The breathing animation is not a 16 s autoreversing loop")
    }
    view.apply(image: image, breathing: false)
    guard view.layer?.mask == nil else { throw fail("Stopping breathing left the mask in place") }
    view.apply(image: image, breathing: true)
    guard view.breathingMask?.animation(forKey: GardenStillView.breatheKey) != nil else { throw fail("Breathing did not restart") }
}

@MainActor private func stillModel(size: CGSize = CGSize(width: 300, height: 200), seed: UInt32 = 3, budget: Int? = nil) -> GardenModel {
    let model = GardenModel()
    model.configure(layout: GardenLayout(size: size, clearingHeight: 20, seed: seed, budget: budget), mode: .still, now: 0)
    return model
}

@MainActor private var lightPalette: VinePalette { VinePalette.make(ThemeSnapshot.current().light, dark: false) }

@MainActor private func pixelWidth(_ image: NSImage?) -> Int? {
    guard let image else { return nil }
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width
}

@MainActor private func checkBitmapScales() throws {
    let model = stillModel()
    let palette = lightPalette
    guard let one = model.raster(palette: palette, scale: 1), let two = model.raster(palette: palette, scale: 2) else { throw fail("No raster") }
    guard pixelWidth(one) == 300, pixelWidth(two) == 600 else {
        throw fail("Raster pixels ignore the requested scale: \(String(describing: pixelWidth(one))) and \(String(describing: pixelWidth(two))) for 300 pt at 1x and 2x")
    }
    guard let frost = model.frostedRaster(palette: palette, scale: 2) else { throw fail("No frost") }
    guard frost.size == two.size else { throw fail("The frost covers \(frost.size), not the garden's \(two.size)") }
    guard let width = pixelWidth(frost), width <= 300 else {
        throw fail("The frost bitmap is \(String(describing: pixelWidth(frost))) px wide; at most half of the 600 px raster")
    }
}

@MainActor private func checkReplantInvalidatesRaster() throws {
    // Two different gardens that happen to grow the same number of steps and cells.
    let size = CGSize(width: 200, height: 160)
    var seen: [String: UInt32] = [:]
    var pair: (UInt32, UInt32)?
    for seed in UInt32(1)...2000 {
        var field = GardenModel.plant(GardenLayout(size: size, clearingHeight: 20, seed: seed, budget: 24))
        field.growToCompletion(limit: 2_000)
        let key = "\(field.stepCount)/\(field.cells.count)"
        if let earlier = seen[key] { pair = (earlier, seed); break }
        seen[key] = seed
    }
    guard let (first, second) = pair else { throw fail("No two seeds produced equal counts to test with") }
    let model = GardenModel()
    let palette = lightPalette
    model.configure(layout: GardenLayout(size: size, clearingHeight: 20, seed: first, budget: 24), mode: .still, now: 0)
    guard let before = model.raster(palette: palette, scale: 1) else { throw fail("No raster") }
    model.configure(layout: GardenLayout(size: size, clearingHeight: 20, seed: second, budget: 24), mode: .still, now: 1)
    guard let after = model.raster(palette: palette, scale: 1) else { throw fail("No raster after replant") }
    guard before !== after else { throw fail("Seeds \(first) and \(second) share step and cell counts and the replant reused the old raster") }
}

@MainActor private func checkFrostMaskCorners() throws {
    let frame = CGRect(x: 10, y: 10, width: 120, height: 80)
    for radius in [CGFloat(0), 9, 10, 20] {
        let mask = FrostMask.path(for: [GlassRegion(frame: frame, cornerRadius: radius)], offset: 0)
        let panel = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: frame)
        for dx in stride(from: CGFloat(0.5), to: 30, by: 1) {
            for dy in stride(from: CGFloat(0.5), to: 30, by: 1) {
                for corner in [CGPoint(x: frame.minX + dx, y: frame.minY + dy), CGPoint(x: frame.maxX - dx, y: frame.maxY - dy)] {
                    guard mask.contains(corner) == panel.contains(corner) else {
                        throw fail("The frost mask differs from a \(radius) pt panel at \(corner)")
                    }
                }
            }
        }
    }
    let shifted = FrostMask.path(for: [GlassRegion(frame: frame, cornerRadius: 0)], offset: 30)
    guard shifted.contains(CGPoint(x: frame.minX + 1, y: frame.minY + 31)), !shifted.contains(CGPoint(x: frame.minX + 1, y: frame.minY + 1)) else {
        throw fail("The frost offset moved the panels wrongly")
    }
}

@MainActor
private final class RegionBox { var regions: [GlassRegion] = [] }

@MainActor private func checkGlassPublishesRadius() throws {
    let box = RegionBox()
    let panels = VStack(spacing: 14) {
        Color.clear.frame(width: 100, height: 40).glassSurface(cornerRadius: 20)
        Color.clear.frame(width: 100, height: 40).glassSurface(cornerRadius: 9)
        Color.clear.frame(width: 100, height: 40).glassSurface(cornerRadius: 0)
    }
    .padding(10)
    .coordinateSpace(name: GardenCanvas.space)
    .environment(\.gardenBackdrop, true)
    .environment(\.nativePreviewOpaque, false)
    .onPreferenceChange(GlassRegionsKey.self) { box.regions = $0 }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let controller = NSHostingController(rootView: panels)
    window.contentViewController = controller
    defer { window.contentViewController = nil; window.close() }
    controller.view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    guard box.regions.count == 3 else { throw fail("Expected three glass regions, got \(box.regions.count)") }
    let ordered = box.regions.sorted { $0.frame.minY < $1.frame.minY }
    guard ordered.map(\.cornerRadius) == [20, 9, 0] else { throw fail("Corner radii \(ordered.map(\.cornerRadius)) are not the call sites' 20, 9, 0") }
    guard ordered.allSatisfy({ abs($0.frame.width - 100) < 0.5 && abs($0.frame.height - 40) < 0.5 }) else { throw fail("Region frames are wrong: \(ordered.map(\.frame))") }
}

@MainActor private func checkFrostRegionsCoalesce() throws {
    let frost = FrostRegions()
    var publishes = 0
    let observer = frost.objectWillChange.sink { publishes += 1 }
    defer { observer.cancel() }
    func region(shift: CGFloat = 0, radius: CGFloat = 20) -> GlassRegion {
        GlassRegion(frame: CGRect(x: 10 + shift, y: 20, width: 100, height: 50), cornerRadius: radius)
    }
    frost.rects = [region()]
    guard publishes == 1 else { throw fail("The first regions were not published") }
    frost.rects = [region()]
    guard publishes == 1 else { throw fail("Identical regions were published again") }
    frost.rects = [region(shift: 0.4)]
    guard publishes == 1 else { throw fail("A sub-point move was published") }
    frost.rects = [region(shift: 0.8)]
    guard publishes == 1 else { throw fail("Sub-point moves accumulated without reaching a point") }
    frost.rects = [region(shift: 1.2)]
    guard publishes == 2, abs((frost.regions.first?.frame.minX ?? 0) - 11.2) < 1e-9 else { throw fail("A move of more than a point was not published") }
    frost.rects = [region(shift: 1.2, radius: 9)]
    guard publishes == 3 else { throw fail("A corner radius change was not published") }
    frost.rects = [region(shift: 1.2, radius: 9), region()]
    guard publishes == 4 else { throw fail("A new panel was not published") }
}

@MainActor private func checkSporesStayClear() throws {
    let w = GardenModel.cellWidth, h = GardenModel.cellHeight
    let clearing: CGFloat = 8 * CGFloat(h)
    // A bloom just under the header clearing; its spores drift up for up to 16 pt/s.
    let avoid = CGRect(x: 300, y: 400, width: 160, height: 60)
    let layout = GardenLayout(size: CGSize(width: 800, height: 600), clearingHeight: clearing, seed: 1, avoid: [avoid])
    let inset = avoid.insetBy(dx: -CGFloat(w), dy: -CGFloat(h))
    var sawSpore = false
    for phase in stride(from: 0.05, to: 1.0, by: 0.07) {
        let bloom = VineCell(x: 10, y: 8, glyph: "✿", alternate: nil, kind: .bloom, slot: 0, step: 0, phase: phase)
        let nearAvoid = VineCell(x: 42, y: 31, glyph: "✿", alternate: nil, kind: .bloom, slot: 0, step: 0, phase: phase)
        for age in stride(from: 0.0, to: 10.0, by: 0.1) {
            for spore in GardenSpores.drifting(from: bloom, age: age, layout: layout, cellWidth: w, cellHeight: h) {
                sawSpore = true
                guard spore.y >= Double(clearing) else {
                    throw fail("A spore drifted to y=\(spore.y), above the \(clearing) pt header clearing (phase \(phase), age \(age))")
                }
            }
            for spore in GardenSpores.drifting(from: nearAvoid, age: age, layout: layout, cellWidth: w, cellHeight: h) {
                let glyph = CGRect(x: spore.x, y: spore.y, width: w, height: h)
                guard !inset.intersects(glyph) else { throw fail("A spore drifted into the avoided rectangle at \(glyph)") }
            }
        }
    }
    let open = VineCell(x: 10, y: 30, glyph: "✿", alternate: nil, kind: .bloom, slot: 0, step: 0, phase: 0.4)
    let clear = GardenSpores.drifting(from: open, age: 1.5, layout: layout, cellWidth: w, cellHeight: h)
    guard sawSpore, !clear.isEmpty, clear.allSatisfy({ $0.alpha > 0 && $0.y < Double(30) * h }) else {
        throw fail("Spores away from the clearing no longer drift up")
    }
}

/// Developer measurement, not one of the checks: run `STILLLEAF_MEASURE_GARDEN=1 BooksPresence --self-test-ui`
/// (`=off` measures the same Library with the garden switched off, to isolate the garden's share).
/// Opens the synthetic Library over the garden, waits for growth to settle, then reports the
/// process's CPU use while idle and while the Library scrolls.
@MainActor
func measureGardenCPU() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-garden-measure-\(UUID().uuidString)")
    let suite = "Stillleaf.GardenMeasure.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: support); defaults.removePersistentDomain(forName: suite); ThemeStore.shared.reload(from: .standard) }
    ThemeStore.shared.reload(from: defaults)
    ThemeStore.shared.select(appearance: .dark)
    if ProcessInfo.processInfo.environment["STILLLEAF_MEASURE_GARDEN"] == "off" { ThemeStore.shared.select(garden: .off) }
    try seedPreviewHistory(at: support)
    let store = try ReadingStore(url: support.appendingPathComponent("history.sqlite"))
    for index in 0..<72 { try store.saveBook(BookRecord(id: "measure-\(index)", title: "Measured Book \(index)", author: "Synthetic Author")) }
    let model = try AppModel(support: support, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: DashboardView(model: model, initialSection: .library))
    window.center()
    NSApp.finishLaunching()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.contentViewController = nil; window.close() }

    func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
    func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
    func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func measure(_ seconds: Double, each frame: () -> Void) -> Double {
        let start = cpuSeconds(), began = Date()
        while Date().timeIntervalSince(began) < seconds { frame(); pump(1.0 / 60) }
        return (cpuSeconds() - start) / seconds * 100
    }

    pump(45)
    guard let content = window.contentView, let scroller = scrollViews(in: content).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
          let document = scroller.documentView else { throw GardenCheckError.failed("No scroll view found") }
    let travel = max(0, document.frame.height - scroller.contentView.bounds.height)
    print("garden-measure: \(model.books.count) books, scroll travel \(Int(travel)) pt, window visible: \(window.occlusionState.contains(.visible))")
    let idle = measure(10) {}
    print(String(format: "garden-measure: idle %.2f%% CPU", idle))
    let began = Date()
    let scrolling = measure(10) {
        // A smooth 5 s there-and-back sweep of the whole Library.
        let phase = Date().timeIntervalSince(began).truncatingRemainder(dividingBy: 5) / 5
        let y = travel * (1 - cos(phase * 2 * .pi)) / 2
        scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroller.reflectScrolledClipView(scroller.contentView)
    }
    print(String(format: "garden-measure: scrolling %.2f%% CPU", scrolling))
}

import AppKit
import SwiftUI

enum GardenCorner: Equatable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
}

/// Where and how a garden grows. `size` is filled in by `GardenCanvas` from its geometry.
struct GardenLayout: Equatable {
    var size: CGSize = .zero
    /// Height of the band at the top kept clear for text drawn straight on the canvas.
    var clearingHeight: CGFloat = 0
    var seed: UInt32
    /// Vines rising evenly from the bottom edge; zero for corner-only gardens.
    var roots = 9
    var pollen = true
    /// Scales the pollen field's opacity (History halves it behind its charts).
    var pollenScale = 1.0
    /// Rectangles holding bare text; vines stay one cell away.
    var avoid: [CGRect] = []
    var cornerRoots: [GardenCorner] = []
    var budget: Int? = nil

    /// Small size jitter during layout should not regrow the garden.
    func growsLike(_ other: GardenLayout) -> Bool {
        abs(size.width - other.size.width) < 8 && abs(size.height - other.size.height) < 8
            && clearingHeight == other.clearingHeight && seed == other.seed && roots == other.roots
            && avoid == other.avoid && cornerRoots == other.cornerRoots && budget == other.budget
    }
}

/// Holds one garden's growth over time. The renderer asks it to advance each frame.
@MainActor
final class GardenModel: ObservableObject {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let cellWidth = Double(("M" as NSString).size(withAttributes: [.font: font]).width)
    static let cellHeight = (13 * 1.22).rounded()

    /// Flips when growth finishes so the timeline can slow from 60 to 20 fps.
    @Published private(set) var growing = false
    private(set) var field = VineField(columns: 1, rows: 1, cellWidth: cellWidth, cellHeight: cellHeight, seed: 1, maxCells: 0)
    private(set) var layout: GardenLayout?
    private var mode: GardenMode = .off
    private var stepTimes: [TimeInterval] = []
    private var lastTime: TimeInterval?
    private var accumulator = 0.0

    /// Growth steps per second while animating.
    static let stepsPerSecond = 14.0

    func configure(layout: GardenLayout, mode: GardenMode, now: TimeInterval) {
        if let current = self.layout, current.growsLike(layout), mode == self.mode { return }
        self.layout = layout
        self.mode = mode
        stepTimes = []
        lastTime = nil
        accumulator = 0
        guard mode != .off, layout.size.width > 0, layout.size.height > 0 else {
            field = VineField(columns: 1, rows: 1, cellWidth: Self.cellWidth, cellHeight: Self.cellHeight, seed: 1, maxCells: 0)
            setGrowing(false)
            return
        }
        field = Self.plant(layout)
        if mode == .still || GardenClock.frozenTime != nil {
            field.growToCompletion(limit: 20_000)
            // Grown long ago: every cell is fully faded in.
            stepTimes = Array(repeating: now - 100, count: field.stepCount)
        }
        setGrowing(field.isGrowing)
    }

    func advance(to now: TimeInterval) {
        guard mode == .animated, field.isGrowing else { return }
        let elapsed = min(0.1, now - (lastTime ?? now))
        lastTime = now
        accumulator += elapsed * Self.stepsPerSecond
        while accumulator >= 1 && field.isGrowing {
            field.step()
            stepTimes.append(now)
            accumulator -= 1
        }
        if !field.isGrowing { DispatchQueue.main.async { self.setGrowing(false) } }
    }

    func bornTime(_ step: Int) -> TimeInterval {
        step < stepTimes.count ? stepTimes[step] : .infinity
    }

    private func setGrowing(_ value: Bool) {
        if growing != value { growing = value }
    }

    static func plant(_ layout: GardenLayout) -> VineField {
        let columns = Int(layout.size.width / cellWidth) + 1
        let rows = Int(layout.size.height / cellHeight) + 1
        let limit = layout.budget ?? 2400
        var field = VineField(columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight, seed: layout.seed, maxCells: limit)
        field.budget = limit
        field.maxTips = 70
        let clearingRows = Int((Double(layout.clearingHeight) / cellHeight).rounded(.up))
        let avoid = layout.avoid.map { $0.insetBy(dx: -CGFloat(cellWidth), dy: -CGFloat(cellHeight)) }
        field.allows = { x, y in
            guard y >= clearingRows else { return false }
            if avoid.isEmpty { return true }
            let cell = CGRect(x: Double(x) * cellWidth, y: Double(y) * cellHeight, width: cellWidth, height: cellHeight)
            return !avoid.contains { $0.intersects(cell) }
        }
        var random = VineRandom(seed: layout.seed ^ 0x9E37_79B9)
        let bottom = rows - 1
        if layout.roots > 0 {
            for i in 0..<layout.roots {
                let x = Int((Double(i) + 0.5) * Double(columns) / Double(layout.roots) + (random.next() - 0.5) * 6)
                field.plant(VineTipSpec(x: min(columns - 1, max(0, x)), y: bottom, heading: -.pi / 2 + (random.next() - 0.5) * 0.6,
                                        life: 30 + Int(random.next() * 26), bias: -.pi / 2, biasStrength: 0.035, hue: i,
                                        branchChance: 0.085, branchLife: 18))
            }
            field.plant(VineTipSpec(x: columns - 1, y: clearingRows + 2, heading: 2.6, life: 40, bias: 2.0, biasStrength: 0.04, hue: 2))
            field.plant(VineTipSpec(x: 0, y: clearingRows + 6, heading: 0.5, life: 36, bias: 0.9, biasStrength: 0.04, hue: 1))
        }
        for corner in layout.cornerRoots {
            let (x, y, heading, bias): (Int, Int, Double, Double)
            switch corner {
            case .topTrailing: (x, y, heading, bias) = (columns - 1, clearingRows, 2.3, 2.0)
            case .topLeading: (x, y, heading, bias) = (0, clearingRows, 0.8, 1.1)
            case .bottomTrailing: (x, y, heading, bias) = (columns - 1, bottom, -2.3, -2.0)
            case .bottomLeading: (x, y, heading, bias) = (0, bottom, -0.8, -1.1)
            }
            field.plant(VineTipSpec(x: x, y: y, heading: heading, life: 46, bias: bias, biasStrength: 0.04, branchChance: 0.1))
        }
        return field
    }
}

/// The ASCII garden: a drifting pollen field and vines, drawn behind glass.
/// Decorative only; it never takes input and is hidden from VoiceOver.
struct GardenCanvas: View {
    let layout: GardenLayout
    let mode: GardenMode
    @StateObject private var model = GardenModel()
    @State private var visible = true
    @Environment(\.colorScheme) private var colorScheme

    init(layout: GardenLayout, mode: GardenMode) {
        self.layout = layout
        self.mode = mode
    }

    var body: some View {
        GeometryReader { proxy in
            let sized = sizedLayout(proxy.size)
            surface
                .onAppear { model.configure(layout: sized, mode: mode, now: Self.now) }
                .onChange(of: sized) { model.configure(layout: $0, mode: mode, now: Self.now) }
                .onChange(of: mode) { model.configure(layout: sized, mode: $0, now: Self.now) }
        }
        .background(WindowVisibility(isVisible: $visible))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func sizedLayout(_ size: CGSize) -> GardenLayout {
        var sized = layout
        sized.size = size
        return sized
    }

    @ViewBuilder private var surface: some View {
        if mode == .off {
            Color.clear
        } else if visible, let interval = GardenClock(mode: mode).frameInterval(growing: model.growing) {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                canvas(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvas(time: GardenClock.frozenTime.map { Self.now - 100 + $0 } ?? Self.now)
        }
    }

    private static var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

    private func canvas(time: TimeInterval) -> some View {
        let dark = colorScheme == .dark
        let snapshot = ThemeSnapshot.current()
        let palette = VinePalette.make(dark ? snapshot.dark : snapshot.light, dark: dark)
        let animated = mode == .animated && GardenClock.frozenTime == nil
        return Canvas { context, _ in
            model.advance(to: time)
            GardenRenderer(model: model, palette: palette, time: time, animated: animated).draw(in: &context)
        }
    }
}

/// Draws one frame of a garden. Kept apart from the view so the maths reads in one place.
@MainActor
private struct GardenRenderer {
    let model: GardenModel
    let palette: VinePalette
    let time: TimeInterval
    let animated: Bool

    func draw(in context: inout GraphicsContext) {
        let field = model.field
        guard let layout = model.layout, field.maxCells > 0 else { return }
        let w = field.cellWidth, h = field.cellHeight
        var glyphs: [String: GraphicsContext.ResolvedText] = [:]
        func glyph(_ character: Character, _ hex: UInt32) -> GraphicsContext.ResolvedText {
            let key = "\(character)\(hex)"
            if let cached = glyphs[key] { return cached }
            let resolved = context.resolve(Text(String(character)).font(.system(size: 13, design: .monospaced))
                .foregroundColor(Color(ReadingPalette.nsColor(hex))))
            glyphs[key] = resolved
            return resolved
        }
        func put(_ text: GraphicsContext.ResolvedText, _ x: Double, _ y: Double, _ alpha: Double) {
            guard alpha > 0.01 else { return }
            var cell = context
            cell.opacity = min(1, alpha)
            cell.draw(text, at: CGPoint(x: x, y: y), anchor: .topLeading)
        }

        if layout.pollen {
            let clearingRows = Int((Double(layout.clearingHeight) / h).rounded(.up))
            let drift = animated ? time : 0
            for y in clearingRows..<field.rows {
                for x in stride(from: 0, to: field.columns, by: 2) {
                    let n = Noise.value(Double(x) * 0.055 + drift * 0.09, Double(y) * 0.11 - drift * 0.05) * 0.65
                        + Noise.value(Double(x) * 0.13 - drift * 0.04, Double(y) * 0.23 + drift * 0.07) * 0.35
                    let alpha = palette.pollenAlpha * layout.pollenScale * smoothstep(0.42, 0.85, n)
                    guard alpha > 0.012 else { continue }
                    let character = VineGlyphs.pollen[Int(Noise.hash(x * 7, y * 13) * Double(VineGlyphs.pollen.count))]
                    put(glyph(character, palette.pollen), Double(x) * w, Double(y) * h, alpha)
                }
            }
        }

        for cell in field.cells.values {
            let born = model.bornTime(cell.step)
            var alpha = smoothstep(0, 0.7, time - born) * palette.baseAlpha
            guard alpha > 0.01 else { continue }
            if animated {
                alpha *= 0.84 + 0.16 * sin(time * 0.9 + cell.phase * 0.35 + Double(cell.x) * 0.11 - Double(cell.y) * 0.17)
            }
            if cell.kind == .stem { alpha *= 0.9 }
            let hex = palette.color(cell.kind, slot: cell.slot)
            let x = Double(cell.x) * w, y = Double(cell.y) * h
            var flutter = 0.0
            if animated, cell.kind == .leaf, cell.alternate != nil {
                flutter = smoothstep(0.88, 1, sin(time * 1.25 - Double(cell.x) * 0.085 + Double(cell.y) * 0.05 + cell.phase * 0.08))
            }
            if flutter > 0, let alternate = cell.alternate {
                put(glyph(cell.glyph, hex), x, y, alpha * (1 - flutter))
                put(glyph(alternate, hex), x, y, alpha * flutter)
            } else {
                put(glyph(cell.glyph, hex), x, y, alpha)
            }
            guard cell.kind == .bloom else { continue }
            let age = time - born
            // A new bloom flashes as it opens, then releases two spores that drift up.
            let pop = 1 - smoothstep(0, 0.9, age)
            if pop > 0 { put(glyph(cell.glyph, hex), x, y - pop * 2, pop * 0.6) }
            if animated && age < 10 {
                for spore in 0..<2 {
                    let seed = cell.phase * 10 + Double(spore)
                    let vx = (Noise.unit(seed) - 0.5) * 6, vy = -(6 + Noise.unit(seed + 3) * 10)
                    let life = 5 + Noise.unit(seed + 7) * 5
                    guard age < life else { continue }
                    let sx = x + w / 2 + vx * age + sin(age * 1.3 + seed) * 6, sy = y + vy * age
                    put(glyph(VineGlyphs.sporeGlyph(Int(seed)), palette.leaves[1]), sx, sy,
                        0.7 * smoothstep(0, 0.8, age) * (1 - smoothstep(life - 1.6, life, age)))
                }
            }
        }

        if animated && field.isGrowing {
            for head in field.heads {
                put(glyph("•", palette.head), head.x - w * 0.5, head.y - h * 0.55, 0.85)
            }
        }
    }

    private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}

extension VineGlyphs {
    static let spores: [Character] = ["·", "∙", "°", "˚"]
    static func sporeGlyph(_ index: Int) -> Character { spores[((index % spores.count) + spores.count) % spores.count] }
}

/// Value noise for the pollen drift, and stable per-cell hashes.
enum Noise {
    static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double(h ^ (h >> 16)) / 4_294_967_296
    }

    static func unit(_ seed: Double) -> Double {
        let s = sin(seed * 12.9898) * 43_758.5453
        return s - s.rounded(.down)
    }

    static func value(_ x: Double, _ y: Double) -> Double {
        let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
        let xf = x - Double(xi), yf = y - Double(yi)
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
        let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }
}

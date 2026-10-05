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
    fileprivate var cachedRaster: NSImage?
    fileprivate var cachedRasterKey: RasterKey?
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

/// The ASCII garden: a pollen field and vines, drawn behind glass. While it
/// grows it redraws at up to 30 fps from cached glyph bitmaps; once grown it
/// becomes one raster whose breathing is a slow light band moved by the
/// compositor, so an idle garden costs almost nothing. Decorative only: it
/// never takes input and is hidden from VoiceOver.
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
            surface(size: proxy.size)
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

    private var palette: VinePalette {
        let dark = colorScheme == .dark
        let snapshot = ThemeSnapshot.current()
        return VinePalette.make(dark ? snapshot.dark : snapshot.light, dark: dark)
    }

    @ViewBuilder private func surface(size: CGSize) -> some View {
        if mode == .off {
            Color.clear
        } else if visible, let interval = GardenClock(mode: mode).frameInterval(growing: model.growing) {
            let palette = palette
            TimelineView(.periodic(from: .now, by: interval)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                Canvas { graphics, _ in
                    model.advance(to: time)
                    GardenRenderer(model: model, palette: palette, time: time).draw(in: &graphics)
                }
            }
        } else if let image = model.raster(palette: palette) {
            GardenStill(image: image, size: size, breathing: mode == .animated && visible && GardenClock.frozenTime == nil)
        }
    }

    private static var now: TimeInterval { Date().timeIntervalSinceReferenceDate }
}

/// A grown garden: one image, with a soft band of light drifting across it.
private struct GardenStill: View {
    let image: NSImage
    let size: CGSize
    let breathing: Bool
    @State private var sweep = false

    var body: some View {
        Image(nsImage: image)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .mask {
                if breathing {
                    LinearGradient(stops: [.init(color: .white.opacity(0.74), location: 0), .init(color: .white, location: 0.5),
                                           .init(color: .white.opacity(0.74), location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: size.width * 3)
                        .offset(x: sweep ? size.width : -size.width)
                        .frame(width: size.width, height: size.height)
                        .onAppear { withAnimation(.linear(duration: 16).repeatForever(autoreverses: true)) { sweep = true } }
                } else {
                    Color.white
                }
            }
    }
}

/// Small bitmaps of each glyph in each colour, drawn once and reused every frame.
@MainActor
enum GlyphAtlas {
    private static var images: [String: NSImage] = [:]

    static func image(_ glyph: Character, _ hex: UInt32) -> NSImage {
        let key = "\(glyph)\(hex)"
        if let cached = images[key] { return cached }
        if images.count > 600 { images.removeAll(keepingCapacity: true) }
        let size = CGSize(width: GardenModel.cellWidth * 1.6, height: GardenModel.cellHeight)
        let image = GardenModel.bitmap(size: size) {
            NSAttributedString(string: String(glyph), attributes: [.font: GardenModel.font, .foregroundColor: ReadingPalette.nsColor(hex)])
                .draw(at: .zero)
        }
        images[key] = image
        return image
    }
}

extension GardenModel {
    /// The grown garden as one image: pollen, then every cell at rest.
    func raster(palette: VinePalette) -> NSImage? {
        guard let layout, field.maxCells > 0, layout.size.width > 0 else { return nil }
        let key = RasterKey(steps: field.stepCount, cells: field.cells.count, palette: palette, size: layout.size, pollenScale: layout.pollenScale)
        if let cachedRaster, cachedRasterKey == key { return cachedRaster }
        let field = field, w = field.cellWidth, h = field.cellHeight
        let image = Self.bitmap(size: layout.size) {
            func draw(_ glyph: Character, _ hex: UInt32, _ alpha: Double, _ x: Double, _ y: Double) {
                NSAttributedString(string: String(glyph), attributes: [.font: Self.font,
                    .foregroundColor: ReadingPalette.nsColor(hex).withAlphaComponent(min(1, alpha))]).draw(at: CGPoint(x: x, y: y))
            }
            if layout.pollen {
                GardenRenderer.forEachPollen(field: field, layout: layout, palette: palette, time: 0) { glyph, alpha, x, y in
                    draw(glyph, palette.pollen, alpha, x, y)
                }
            }
            for cell in field.cells.values {
                let alpha = palette.baseAlpha * (cell.kind == .stem ? 0.9 : 1) * 0.92
                draw(cell.glyph, palette.color(cell.kind, slot: cell.slot), alpha, Double(cell.x) * w, Double(cell.y) * h)
            }
        }
        cachedRaster = image
        cachedRasterKey = key
        return image
    }

    /// Draws into a flipped, screen-scale bitmap once, so the result never re-runs drawing code.
    static func bitmap(size: CGSize, _ draw: () -> Void) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(size.width * scale)), pixelsHigh: max(1, Int(size.height * scale)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage(size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cg = context.cgContext
        cg.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
        cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

struct RasterKey: Equatable {
    let steps: Int
    let cells: Int
    let palette: VinePalette
    let size: CGSize
    let pollenScale: Double
}

/// Draws one frame of a growing garden from cached glyph bitmaps.
@MainActor
private struct GardenRenderer {
    let model: GardenModel
    let palette: VinePalette
    let time: TimeInterval

    static func forEachPollen(field: VineField, layout: GardenLayout, palette: VinePalette, time: TimeInterval,
                              _ body: (Character, Double, Double, Double) -> Void) {
        let clearingRows = Int((Double(layout.clearingHeight) / field.cellHeight).rounded(.up))
        guard clearingRows < field.rows else { return }
        for y in clearingRows..<field.rows {
            for x in stride(from: 0, to: field.columns, by: 2) {
                let n = Noise.value(Double(x) * 0.055 + time * 0.09, Double(y) * 0.11 - time * 0.05) * 0.65
                    + Noise.value(Double(x) * 0.13 - time * 0.04, Double(y) * 0.23 + time * 0.07) * 0.35
                let alpha = palette.pollenAlpha * layout.pollenScale * smoothstep(0.42, 0.85, n)
                guard alpha > 0.012 else { continue }
                body(VineGlyphs.pollen[Int(Noise.hash(x * 7, y * 13) * Double(VineGlyphs.pollen.count))], alpha,
                     Double(x) * field.cellWidth, Double(y) * field.cellHeight)
            }
        }
    }

    func draw(in context: inout GraphicsContext) {
        let field = model.field
        guard let layout = model.layout, field.maxCells > 0 else { return }
        let w = field.cellWidth, h = field.cellHeight
        var resolved: [String: GraphicsContext.ResolvedImage] = [:]
        func put(_ glyph: Character, _ hex: UInt32, _ x: Double, _ y: Double, _ alpha: Double) {
            guard alpha > 0.01 else { return }
            let key = "\(glyph)\(hex)"
            let image = resolved[key] ?? context.resolve(Image(nsImage: GlyphAtlas.image(glyph, hex)))
            resolved[key] = image
            var cell = context
            cell.opacity = min(1, alpha)
            cell.draw(image, at: CGPoint(x: x, y: y), anchor: .topLeading)
        }
        if layout.pollen {
            // The field fades in as the garden starts to grow.
            let fade = smoothstep(0, 1.4, time - model.bornTime(0))
            Self.forEachPollen(field: field, layout: layout, palette: palette, time: 0) { glyph, alpha, x, y in
                put(glyph, palette.pollen, x, y, alpha * fade)
            }
        }
        for cell in field.cells.values {
            let born = model.bornTime(cell.step)
            let alpha = smoothstep(0, 0.7, time - born) * palette.baseAlpha * (cell.kind == .stem ? 0.9 : 1) * 0.92
            guard alpha > 0.01 else { continue }
            let hex = palette.color(cell.kind, slot: cell.slot)
            let x = Double(cell.x) * w, y = Double(cell.y) * h
            put(cell.glyph, hex, x, y, alpha)
            guard cell.kind == .bloom else { continue }
            let age = time - born
            // A new bloom flashes as it opens, then releases two spores that drift up.
            let pop = 1 - smoothstep(0, 0.9, age)
            if pop > 0 { put(cell.glyph, hex, x, y - pop * 2, pop * 0.6) }
            for spore in 0..<2 where age < 10 {
                let seed = cell.phase * 10 + Double(spore)
                let vx = (Noise.unit(seed) - 0.5) * 6, vy = -(6 + Noise.unit(seed + 3) * 10)
                let life = 5 + Noise.unit(seed + 7) * 5
                guard age < life else { continue }
                put(VineGlyphs.sporeGlyph(Int(seed)), palette.leaves[1], x + w / 2 + vx * age + sin(age * 1.3 + seed) * 6, y + vy * age,
                    0.7 * smoothstep(0, 0.8, age) * (1 - smoothstep(life - 1.6, life, age)))
            }
        }
        for head in field.heads where field.isGrowing {
            put("•", palette.head, head.x - w * 0.5, head.y - h * 0.55, 0.85)
        }
    }
}

private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
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

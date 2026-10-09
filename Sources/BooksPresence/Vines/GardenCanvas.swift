import AppKit
import CoreImage
import SwiftUI

enum GardenEdge: Equatable {
    case leading, trailing, top, bottom
}

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
    /// Keeps vines within this many cells of the edges, for panels whose
    /// text fills the middle.
    var edgeBand: Int? = nil
    /// Which edges `edgeBand` hugs.
    var bandEdges: [GardenEdge] = [.leading, .trailing, .top, .bottom]
    /// Multiplies how long vines grow, for gardens with little open space.
    var vigor = 1.0
    /// Grows only this fraction of the full garden (0…1); raising it extends the same garden.
    var growth: Double? = nil
    /// Keeps moving once grown: new shoots, withering, wind, petals and fireflies. Off for
    /// gardens that are meant to stand still, such as the onboarding tour's.
    var living = false
    /// Fireflies by night, pollen motes by day, drifting through this garden's free space.
    var fireflies = 0
    /// Seconds between petals shed by this garden's blooms.
    var petalEvery = 9.0

    /// Small size jitter during layout should not regrow the garden.
    func growsLike(_ other: GardenLayout) -> Bool {
        abs(size.width - other.size.width) < 8 && abs(size.height - other.size.height) < 8
            && clearingHeight == other.clearingHeight && seed == other.seed && roots == other.roots
            && avoid == other.avoid && cornerRoots == other.cornerRoots && budget == other.budget && edgeBand == other.edgeBand && bandEdges == other.bandEdges && vigor == other.vigor && growth == other.growth
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
    /// Changes whenever the garden is (re)configured, so the view redraws the new garden.
    @Published private(set) var revision = 0
    private(set) var field = VineField(columns: 1, rows: 1, cellWidth: cellWidth, cellHeight: cellHeight, seed: 1, maxCells: 0)
    private(set) var layout: GardenLayout?
    /// Increments on every full replant, so callers can tell regrowth from a kept garden.
    private(set) var generation = 0
    private var mode: GardenMode = .off
    private var stepTimes: [TimeInterval] = []
    fileprivate var cachedRaster: NSImage?
    fileprivate var cachedRasterKey: RasterKey?
    fileprivate var cachedFrost: NSImage?
    fileprivate var cachedFrostKey: RasterKey?
    private var lastTime: TimeInterval?
    private var accumulator = 0.0
    /// The grown garden's ongoing life, once the garden has finished growing and its layout asks to live.
    private(set) var living: LivingGarden?

    /// Growth steps per second while animating.
    static let stepsPerSecond = 14.0

    func configure(layout: GardenLayout, mode: GardenMode, now: TimeInterval) {
        if let current = self.layout, current.growsLike(layout), mode == self.mode { return }
        defer { revision += 1 }
        // A different header clearing (History's taller header) keeps the garden;
        // cells inside the clearing are simply not drawn.
        if let current = self.layout, mode == self.mode, current.clearingHeight != layout.clearingHeight {
            var unchanged = layout
            unchanged.clearingHeight = current.clearingHeight
            if current.growsLike(unchanged) {
                self.layout = layout
                cachedRaster = nil
                return
            }
        }
        // A larger budget or growth fraction alone keeps the garden and grows it further.
        if let current = self.layout, mode == self.mode, mode != .off, field.maxCells > 0 {
            var unchanged = layout
            unchanged.budget = current.budget
            unchanged.growth = current.growth
            let grows = (layout.budget ?? 0) > (current.budget ?? 0) || (layout.growth ?? 0) > (current.growth ?? 0)
            if grows && current.growsLike(unchanged) {
                self.layout = layout
                living = nil
                field.raiseBudget(to: Self.plant(layout).budget)
                if mode == .still || GardenClock.frozenTime != nil {
                    field.growToCompletion(limit: 20_000)
                    stepTimes += Array(repeating: now - 100, count: max(0, field.stepCount - stepTimes.count))
                }
                cachedRaster = nil
                setGrowing(field.isGrowing)
                return
            }
        }
        self.layout = layout
        self.mode = mode
        living = nil
        stepTimes = []
        lastTime = nil
        accumulator = 0
        guard mode != .off, layout.size.width > 0, layout.size.height > 0 else {
            field = VineField(columns: 1, rows: 1, cellWidth: Self.cellWidth, cellHeight: Self.cellHeight, seed: 1, maxCells: 0)
            setGrowing(false)
            return
        }
        field = Self.plant(layout)
        generation += 1
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

    /// Starts the grown garden living, if its layout asks and it has finished growing. Keeps a garden already living.
    func beginLiving() {
        guard living == nil, let layout, layout.living, mode == .animated, field.maxCells > 0, !field.isGrowing else { return }
        living = LivingGarden(field: field, roots: layout.roots, seed: layout.seed, petalEvery: layout.petalEvery)
    }

    /// Starts the living garden over from the grown garden, for renders at a fixed moment.
    func restartLiving() {
        living = nil
        beginLiving()
    }

    @discardableResult
    func advanceLiving(to time: TimeInterval) -> LivingGarden.Changes {
        living?.advance(to: time) ?? LivingGarden.Changes()
    }

    var livingTime: TimeInterval { living?.time ?? 0 }

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
        var field = VineField(columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight, seed: layout.seed, maxCells: max(limit, 2400))
        field.budget = limit
        field.maxTips = 70
        let clearingRows = Int((Double(layout.clearingHeight) / cellHeight).rounded(.up))
        let avoid = layout.avoid.map { $0.insetBy(dx: -CGFloat(cellWidth), dy: -CGFloat(cellHeight)) }
        let band = layout.edgeBand, edges = layout.bandEdges
        field.allows = { x, y in
            guard y >= clearingRows else { return false }
            if let band {
                let distances: [(GardenEdge, Int)] = [(.leading, x), (.top, y - clearingRows), (.trailing, columns - 1 - x), (.bottom, rows - 1 - y)]
                guard distances.contains(where: { edges.contains($0.0) && $0.1 < band }) else { return false }
            }
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
                                        life: Int(Double(30 + Int(random.next() * 26)) * layout.vigor), bias: -.pi / 2, biasStrength: 0.035, hue: i,
                                        branchChance: 0.085, branchLife: Int(18 * layout.vigor)))
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
        if let growth = layout.growth {
            // Measure the full garden, then stop at a fraction of it. Growth is deterministic,
            // so a larger fraction later continues the same garden.
            var full = field
            full.budget = .max
            full.growToCompletion(limit: 20_000)
            field.budget = max(24, Int((Double(full.cells.count) * min(1, max(0, growth))).rounded()))
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
    /// The coordinate space glass panels report their frames in.
    static let space = "garden"
    let layout: GardenLayout
    let mode: GardenMode
    /// Glass panel frames to frost, and how far the garden's origin sits above that space.
    let frost: FrostRegions?
    let frostOffset: CGFloat
    @StateObject private var model = GardenModel()
    @State private var visible = true
    @State private var resizing = false
    @State private var pendingLayout: GardenLayout?
    /// Bumped now and then while the garden lives, so the glass's blurred copy catches up with it.
    @State private var frostEpoch = 0
    /// Pixels per point of the hosting window, so bitmaps are no larger than that display needs.
    @State private var scale = NSScreen.main?.backingScaleFactor ?? 2
    /// Observed so a theme or accent change recolours the garden.
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.colorScheme) private var colorScheme

    init(layout: GardenLayout, mode: GardenMode, frost: FrostRegions? = nil, frostOffset: CGFloat = 0) {
        self.layout = layout
        self.mode = mode
        self.frost = frost
        self.frostOffset = frostOffset
    }

    var body: some View {
        GeometryReader { proxy in
            let sized = sizedLayout(proxy.size)
            // An always-present base: before the first configure the surface is empty,
            // and SwiftUI may not deliver onAppear to an empty view.
            ZStack(alignment: .topLeading) { Color.clear; surface(size: proxy.size) }
                .onAppear { model.configure(layout: sized, mode: mode, now: Self.now) }
                .onChange(of: sized) { layout in
                    // Replant once when a live resize ends, not every few points of the drag.
                    if resizing { pendingLayout = layout } else { model.configure(layout: layout, mode: mode, now: Self.now) }
                }
                .onChange(of: mode) { model.configure(layout: sized, mode: $0, now: Self.now) }
                .onChange(of: resizing) { live in
                    if !live, let pending = pendingLayout { pendingLayout = nil; model.configure(layout: pending, mode: mode, now: Self.now) }
                }
        }
        .background(WindowVisibility(isVisible: $visible, isResizing: $resizing))
        .background(WindowScale(scale: $scale))
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
        if let frost, mode != .off {
            // Sharp vines stop at the glass; inside it the garden shows through softly blurred.
            ZStack(alignment: .topLeading) {
                sharp(size: size).mask(FrostMask(regions: frost, offset: frostOffset, inverted: true))
                if !model.growing, let image = model.frostedRaster(palette: palette, scale: scale) {
                    Image(nsImage: image)
                        .resizable().interpolation(.high)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .mask(FrostMask(regions: frost, offset: frostOffset, inverted: false))
                        .id(frostEpoch)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.6), value: model.growing)
            .animation(.easeInOut(duration: 2), value: frostEpoch)
        } else {
            sharp(size: size)
        }
    }

    @ViewBuilder private func sharp(size: CGSize) -> some View {
        if mode == .off {
            Color.clear
        } else if visible, let interval = GardenClock(mode: mode).frameInterval(growing: model.growing) {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let palette = palette
                Canvas { graphics, _ in
                    model.advance(to: time)
                    GardenRenderer(model: model, palette: palette, time: time).draw(in: &graphics)
                }
            }
        } else if livesNow {
            LivingGardenLayer(model: model, palette: palette, dark: colorScheme == .dark, scale: scale, active: visible,
                              frost: frost, frostOffset: frostOffset, frozenAt: GardenClock.livingTime,
                              onFrostStale: { frostEpoch += 1 })
                .frame(width: size.width, height: size.height)
        } else if let image = model.raster(palette: palette, scale: scale) {
            GardenStill(image: image, breathing: mode == .animated && visible && GardenClock.frozenTime == nil)
                .frame(width: size.width, height: size.height)
        }
    }

    /// A grown garden that keeps moving: Animated mode, a layout that asks to live, and no render
    /// frozen at a fixed moment (unless that render asks for a living moment).
    private var livesNow: Bool {
        layout.living && mode == .animated && !model.growing && model.field.maxCells > 0
            && (GardenClock.frozenTime == nil || GardenClock.livingTime != nil)
    }

    private static var now: TimeInterval { Date().timeIntervalSinceReferenceDate }
}

/// Glass panels, observed only by the garden so scrolling never
/// re-renders the screens themselves.
@MainActor
final class FrostRegions: ObservableObject {
    @Published private(set) var regions: [GlassRegion] = []

    /// Where `GlassRegionsKey` values are delivered. Moves under a point are not
    /// published: the frost would not visibly differ, and the garden skips a redraw.
    var rects: [GlassRegion] {
        get { regions }
        set { if !Self.equivalent(regions, newValue) { regions = newValue } }
    }

    private static func equivalent(_ old: [GlassRegion], _ new: [GlassRegion]) -> Bool {
        guard old.count == new.count else { return false }
        return zip(old, new).allSatisfy { a, b in
            a.cornerRadius == b.cornerRadius && abs(a.frame.minX - b.frame.minX) < 1 && abs(a.frame.minY - b.frame.minY) < 1
                && abs(a.frame.width - b.frame.width) < 1 && abs(a.frame.height - b.frame.height) < 1
        }
    }
}

/// The union of glass panels (or everything but them, when inverted).
struct FrostMask: View {
    @ObservedObject var regions: FrostRegions
    let offset: CGFloat
    let inverted: Bool

    /// The panels' outlines, each with its own corner radius.
    static func path(for regions: [GlassRegion], offset: CGFloat) -> Path {
        var panels = Path()
        for region in regions {
            panels.addRoundedRect(in: region.frame.offsetBy(dx: 0, dy: offset), cornerSize: CGSize(width: region.cornerRadius, height: region.cornerRadius), style: .continuous)
        }
        return panels
    }

    var body: some View {
        Canvas { context, size in
            let panels = Self.path(for: regions.regions, offset: offset)
            if inverted {
                var everything = Path(CGRect(origin: .zero, size: size))
                everything.addPath(panels)
                context.fill(everything, with: .color(.white), style: FillStyle(eoFill: true))
            } else {
                context.fill(panels, with: .color(.white))
            }
        }
    }
}

/// A grown garden: one layer, with a soft band of light drifting across it.
private struct GardenStill: NSViewRepresentable {
    let image: NSImage
    let breathing: Bool

    func makeNSView(context: Context) -> GardenStillView { GardenStillView(frame: .zero) }
    func updateNSView(_ view: GardenStillView, context: Context) { view.apply(image: image, breathing: breathing) }
}

/// Shows the grown garden as one layer. While `breathing`, its mask carries a band of light
/// that a Core Animation animation sweeps across: the render server runs it, so the idle
/// garden asks nothing of the app (a SwiftUI `repeatForever` kept the app re-evaluating
/// the view tree every frame). Stopping removes the mask, and breathing again starts afresh.
final class GardenStillView: NSView {
    static let breatheKey = "breathe"
    /// Seconds for the band to cross the garden, as the SwiftUI animation it replaces did; it then sweeps back.
    static let breathePeriod: CFTimeInterval = 16
    private var image: NSImage?
    private var breathing = false
    private var bandWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var breathingMask: CALayer? { layer?.mask }

    func apply(image: NSImage, breathing: Bool) {
        if self.image !== image { self.image = image; needsDisplay = true }
        guard breathing != self.breathing else { return }
        self.breathing = breathing
        refreshBand()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contentsGravity = .resize
        layer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if breathing, bandWidth != newSize.width { refreshBand() }
    }

    /// The mask is a gradient three garden-widths wide whose centre travels from just left of the
    /// garden to beyond its right edge, so the garden's brightness drifts between 74% and 100%.
    private func refreshBand() {
        guard let layer else { return }
        guard breathing else { layer.mask = nil; return }
        let width = bounds.width, height = bounds.height
        bandWidth = width
        layer.mask = BreathingBand.make(width: width, height: height)
    }
}

/// Reports the hosting window's backing scale, and follows it across displays.
private struct WindowScale: NSViewRepresentable {
    @Binding var scale: CGFloat

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.report = { value in
            DispatchQueue.main.async { if scale != value { scale = value } }
        }
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        var report: ((CGFloat) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: window, queue: .main) { [weak self] _ in
                self?.report?(window.backingScaleFactor)
            }
            report?(window.backingScaleFactor)
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }
}

/// Small bitmaps of each glyph in each colour, drawn once and reused every frame.
@MainActor
enum GlyphAtlas {
    private static var images: [String: NSImage] = [:]
    private struct BitmapKey: Hashable { let glyph: Character; let hex: UInt32; let scale: CGFloat }
    private static var cgImages: [BitmapKey: CGImage] = [:]

    /// The glyph's bitmap for drawing into a layer or a tile.
    static func cgImage(_ glyph: Character, _ hex: UInt32, scale: CGFloat) -> CGImage? {
        let key = BitmapKey(glyph: glyph, hex: hex, scale: scale)
        if let cached = cgImages[key] { return cached }
        if cgImages.count > 1200 { cgImages.removeAll(keepingCapacity: true) }
        let image = image(glyph, hex, scale: scale).cgImage(forProposedRect: nil, context: nil, hints: nil)
        cgImages[key] = image
        return image
    }

    static func image(_ glyph: Character, _ hex: UInt32, scale: CGFloat) -> NSImage {
        let key = "\(glyph)\(hex)@\(scale)"
        if let cached = images[key] { return cached }
        if images.count > 1200 { images.removeAll(keepingCapacity: true) }
        let size = CGSize(width: GardenModel.cellWidth * 1.6, height: GardenModel.cellHeight)
        let image = GardenModel.bitmap(size: size, scale: scale) {
            NSAttributedString(string: String(glyph), attributes: [.font: GardenModel.font, .foregroundColor: ReadingPalette.nsColor(hex)])
                .draw(at: .zero)
        }
        images[key] = image
        return image
    }
}

extension GardenModel {
    /// The grown garden as one image: pollen, then every cell at rest.
    func raster(palette: VinePalette, scale: CGFloat) -> NSImage? {
        guard let layout, field.maxCells > 0, layout.size.width > 0 else { return nil }
        // A living garden's current state, not the garden it grew from.
        let field = living?.field ?? self.field
        let key = RasterKey(generation: generation, steps: field.stepCount, cells: field.cells.count, palette: palette, size: layout.size,
                            pollenScale: layout.pollenScale, clearing: layout.clearingHeight, scale: scale)
        if let cachedRaster, cachedRasterKey == key { return cachedRaster }
        let w = field.cellWidth, h = field.cellHeight
        let image = Self.bitmap(size: layout.size, scale: scale) {
            func draw(_ glyph: Character, _ hex: UInt32, _ alpha: Double, _ x: Double, _ y: Double) {
                NSAttributedString(string: String(glyph), attributes: [.font: Self.font,
                    .foregroundColor: ReadingPalette.nsColor(hex).withAlphaComponent(min(1, alpha))]).draw(at: CGPoint(x: x, y: y))
            }
            if layout.pollen {
                GardenRenderer.forEachPollen(field: field, layout: layout, palette: palette, time: 0) { glyph, alpha, x, y in
                    draw(glyph, palette.pollen, alpha, x, y)
                }
            }
            for cell in field.cells.values where Double(cell.y) * h >= Double(layout.clearingHeight) {
                let alpha = palette.baseAlpha * (cell.kind == .stem ? 0.9 : 1) * 0.92
                draw(cell.glyph, palette.color(cell.kind, slot: cell.slot), alpha, Double(cell.x) * w, Double(cell.y) * h)
            }
        }
        cachedRaster = image
        cachedRasterKey = key
        return image
    }

    /// The grown garden softly blurred and a little more saturated: what shows through glass.
    func frostedRaster(palette: VinePalette, scale: CGFloat) -> NSImage? {
        guard let sharp = raster(palette: palette, scale: scale), let key = cachedRasterKey else { return nil }
        if let cachedFrost, cachedFrostKey == key { return cachedFrost }
        guard let cg = sharp.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // The blur hides detail, so build it at a fraction of the raster's resolution: it needs
        // a quarter of the memory, and the image is stretched back over the same points.
        let pixelsPerPoint = Double(cg.width) / max(1, sharp.size.width) * Self.frostDownscale
        let input = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: Self.frostDownscale, y: Self.frostDownscale))
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 2.8 * pixelsPerPoint)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.6, kCIInputBrightnessKey: 0.0])
            .cropped(to: input.extent)
        guard let blurred = Self.imageContext.createCGImage(output, from: input.extent) else { return nil }
        let image = NSImage(cgImage: blurred, size: sharp.size)
        cachedFrost = image
        cachedFrostKey = key
        return image
    }

    /// The frost bitmap's resolution relative to the raster's.
    static let frostDownscale: CGFloat = 0.5

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    /// Draws into a flipped bitmap at the hosting window's scale once, so the result never re-runs drawing code.
    static func bitmap(size: CGSize, scale: CGFloat, _ draw: () -> Void) -> NSImage {
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

/// What a cached raster was drawn from. `generation` counts replants, so a different garden
/// never matches even when it happens to grow the same number of steps and cells.
struct RasterKey: Equatable {
    let generation: Int
    let steps: Int
    let cells: Int
    let palette: VinePalette
    let size: CGSize
    let pollenScale: Double
    let clearing: CGFloat
    /// Pixels per point of the window the raster was drawn for.
    let scale: CGFloat
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
        let scale = context.environment.displayScale
        var resolved: [String: GraphicsContext.ResolvedImage] = [:]
        func put(_ glyph: Character, _ hex: UInt32, _ x: Double, _ y: Double, _ alpha: Double) {
            guard alpha > 0.01 else { return }
            let key = "\(glyph)\(hex)"
            let image = resolved[key] ?? context.resolve(Image(nsImage: GlyphAtlas.image(glyph, hex, scale: scale)))
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
        for cell in field.cells.values where Double(cell.y) * h >= Double(layout.clearingHeight) {
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
            if pop > 0, GardenSpores.isClear(x: x, y: y - pop * 2, layout: layout, cellWidth: w, cellHeight: h) { put(cell.glyph, hex, x, y - pop * 2, pop * 0.6) }
            for spore in GardenSpores.drifting(from: cell, age: age, layout: layout, cellWidth: w, cellHeight: h) {
                put(spore.glyph, palette.leaves[1], spore.x, spore.y, spore.alpha)
            }
        }
        for head in field.heads where field.isGrowing {
            put("•", palette.head, head.x - w * 0.5, head.y - h * 0.55, 0.85)
        }
    }
}

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

/// The pollen a bloom releases as it opens: two spores drifting up and sideways.
enum GardenSpores {
    struct Spore: Equatable {
        let glyph: Character
        let alpha: Double
        let x: Double
        let y: Double
    }

    /// Whether a glyph at (x, y) stays out of the header clearing and a cell clear of every avoided rectangle.
    static func isClear(x: Double, y: Double, layout: GardenLayout, cellWidth w: Double, cellHeight h: Double) -> Bool {
        guard y >= Double(layout.clearingHeight) else { return false }
        if layout.avoid.isEmpty { return true }
        let glyph = CGRect(x: x, y: y, width: w, height: h)
        return !layout.avoid.contains { $0.insetBy(dx: -CGFloat(w), dy: -CGFloat(h)).intersects(glyph) }
    }

    /// One spore's flight from a cell: where it is and how visible, `age` seconds after the cell let go of it.
    struct Flight {
        let glyph: Character
        let life: Double
        private let x0: Double, y0: Double, vx: Double, vy: Double, seed: Double

        init(cell: VineCell, spore: Int, cellWidth w: Double, cellHeight h: Double) {
            seed = cell.phase * 10 + Double(spore)
            vx = (Noise.unit(seed) - 0.5) * 6
            vy = -(6 + Noise.unit(seed + 3) * 10)
            life = 5 + Noise.unit(seed + 7) * 5
            x0 = Double(cell.x) * w + w / 2
            y0 = Double(cell.y) * h
            glyph = VineGlyphs.sporeGlyph(Int(seed))
        }

        func point(age: Double) -> CGPoint { CGPoint(x: x0 + vx * age + sin(age * 1.3 + seed) * 6, y: y0 + vy * age) }
        func alpha(age: Double) -> Double { 0.7 * smoothstep(0, 0.8, age) * (1 - smoothstep(life - 1.6, life, age)) }
    }

    static func flights(from cell: VineCell, cellWidth w: Double, cellHeight h: Double) -> [Flight] {
        (0..<2).map { Flight(cell: cell, spore: $0, cellWidth: w, cellHeight: h) }
    }

    /// Where `cell`'s spores are `age` seconds after it opened. Spores that would drift over
    /// the header or an avoided rectangle are dropped rather than drawn over bare text.
    static func drifting(from cell: VineCell, age: Double, layout: GardenLayout, cellWidth w: Double, cellHeight h: Double) -> [Spore] {
        guard age < 10 else { return [] }
        var spores: [Spore] = []
        for flight in flights(from: cell, cellWidth: w, cellHeight: h) where age < flight.life {
            let point = flight.point(age: age)
            guard isClear(x: point.x, y: point.y, layout: layout, cellWidth: w, cellHeight: h) else { continue }
            spores.append(Spore(glyph: flight.glyph, alpha: flight.alpha(age: age), x: point.x, y: point.y))
        }
        return spores
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

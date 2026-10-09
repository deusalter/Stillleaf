import AppKit
import Combine
import QuartzCore
import SwiftUI

/// The living garden as Core Animation layers. Nothing here redraws on a frame clock:
///
/// - Settled growth is a handful of 256 pt tiles (stems; leaves and blooms at rest; leaves and
///   blooms blown aside). A tile is redrawn only when a cell in it settles or withers, about
///   once every 1 to 2 s while a shoot grows.
/// - Wind is two of those leaf layers cross-fading under gradient masks that the render server
///   moves, like the breathing band; stems stay put.
/// - A newly grown cell, a tip's glowing head, a petal, a spore and a firefly are small layers
///   whose fades and flights are animations the render server runs. The app wakes once per growth
///   step (1.5 s) to hand it the next few.
/// - Hidden, minimised or occluded, the layers and the timer are dropped; on return the garden
///   catches up in one step.
///
/// `GardenModel` owns the garden's state (`LivingGarden`); this view only presents it.
@MainActor
final class LivingGardenView: NSView {
    static let tileSize: CGFloat = 256
    /// Room past a tile's edge for glyphs that overhang their cell.
    static let tileBleed: CGFloat = 8
    /// How long a new cell's layer lives before the tile takes it over.
    static let settleAfter = LivingGarden.fadeIn + 0.05
    /// Seconds between refreshes of the glass's blurred copy of the garden.
    static let frostRefresh = 120.0
    static let breatheKey = GardenStillView.breatheKey
    static let windKey = "wind"
    static let flightKey = "flight"
    static let blinkKey = "blink"

    private struct TileID: Hashable { let x: Int; let y: Int }

    private final class Tile {
        let base = CALayer(), still = CALayer(), flutter = CALayer()
    }

    /// What the layers were built from; anything else changing needs no rebuild.
    private struct Look: Equatable {
        var generation: Int
        var size: CGSize
        var palette: VinePalette
        var scale: CGFloat
        var dark: Bool
        var fireflies: Int
        var clearing: CGFloat
        var frozenAt: Double?
    }

    private weak var model: GardenModel?
    private var look: Look?
    private(set) var isRunning = false
    private var timer: Timer?
    /// Media time at which the garden's own clock read zero.
    private var epoch: CFTimeInterval = 0
    private var lastFrost: Double = 0
    private var stepIndex = 0
    var frostIsStale: (() -> Void)?
    /// Drives itself from a timer; the frame-budget check turns this off and calls `step` itself.
    var drivesItself = true

    private let canvas = CALayer()
    private let base = CALayer(), still = CALayer(), flutter = CALayer(), live = CALayer(), flies = CALayer()
    private var tiles: [TileID: Tile] = [:]
    private var dirty = Set<TileID>()
    /// Cells grown but not yet settled into a tile, by field key, with when they grew.
    private var pending: [Int: Double] = [:]
    private var cellLayers: [Int: CALayer] = [:]
    private var headLayers: [Int: CALayer] = [:]
    private var transient: [(layer: CALayer, until: Double)] = []
    private var keepOut: [CGRect] = []
    private var keepOutWork: DispatchWorkItem?
    private var frostSubscription: AnyCancellable?
    private var frostOffset: CGFloat = 0
    private weak var frost: FrostRegions?

    // MARK: Inspection, for the checks

    struct Summary: Equatable {
        var tiles: Int
        var pending: Int
        var fireflies: Int
        var heads: Int
        var windAnimations: Int
        var hasTimer: Bool
        var transients: Int
    }

    var summary: Summary {
        Summary(tiles: tiles.count, pending: pending.count, fireflies: flies.sublayers?.count ?? 0, heads: headLayers.count,
                windAnimations: [still.mask, flutter.mask].compactMap { $0?.animation(forKey: Self.windKey) }.count,
                hasTimer: timer != nil, transients: transient.count)
    }

    var fireflyLayers: [CALayer] { flies.sublayers ?? [] }
    var tileLayers: [CALayer] { tiles.values.flatMap { [$0.base, $0.still, $0.flutter] } }
    var breathingMask: CALayer? { layer?.mask }

    // MARK: Setup

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        canvas.anchorPoint = .zero
        layer?.addSublayer(canvas)
        for container in [base, still, flutter, live, flies] {
            container.anchorPoint = .zero
            canvas.addSublayer(container)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        placeCanvas()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeCanvas()
        if isRunning, breathingWidth != newSize.width {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.mask = Self.breathingBand(width: bounds.width, height: bounds.height)
            breathingWidth = newSize.width
            CATransaction.commit()
        }
    }

    private var breathingWidth: CGFloat = 0

    private func placeCanvas() {
        guard let look else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Keep the garden's top edge on the view's top, whatever small jitter the height has.
        canvas.position = CGPoint(x: 0, y: bounds.height - look.size.height)
        CATransaction.commit()
    }

    deinit { timer?.invalidate() }

    // MARK: Applying

    /// Brings the view in line with the model. Cheap when nothing changed.
    func apply(model: GardenModel, palette: VinePalette, dark: Bool, scale: CGFloat, active: Bool,
               frost: FrostRegions?, frostOffset: CGFloat, frozenAt: Double?) {
        guard let layout = model.layout, layout.size.width > 0 else { return }
        self.model = model
        let next = Look(generation: model.generation, size: layout.size, palette: palette, scale: scale, dark: dark,
                        fireflies: layout.fireflies, clearing: layout.clearingHeight, frozenAt: frozenAt)
        if next != look {
            rebuild(next)
        }
        self.frostOffset = frostOffset
        if self.frost !== frost {
            self.frost = frost
            frostSubscription = frost?.objectWillChange.sink { [weak self] _ in self?.frostRegionsChanged() }
            updateKeepOut()
        }
        guard next.frozenAt == nil else { return }
        if active, !isRunning { start() } else if !active, isRunning { stop() }
    }

    /// Stops everything and drops the layers that only exist while the garden moves.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate(); timer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Whatever was still fading in is part of the garden now.
        for key in pending.keys { dirtyTile(forKey: key) }
        pending = [:]
        clearTransients()
        still.mask?.removeAllAnimations()
        flutter.mask?.removeAllAnimations()
        layer?.mask = nil
        flies.sublayers?.forEach { $0.removeFromSuperlayer() }
        flush()
        CATransaction.commit()
    }

    /// Starts the garden moving, catching up to `simTime` (default: now) in one step.
    func start(simTime: Double? = nil) {
        guard let model, look != nil, model.living != nil else { return }
        isRunning = true
        // The garden's own clock never stopped: catch up to now in one step, without animating it.
        let t = simTime ?? CACurrentMediaTime() - epoch
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let changes = model.advanceLiving(to: t)
        process(changes, at: t, animated: false)
        layer?.mask = Self.breathingBand(width: bounds.width, height: bounds.height)
        breathingWidth = bounds.width
        installWind(frozenAt: nil)
        buildFireflies(frozenAt: nil)
        flush()
        CATransaction.commit()
        lastFrost = t
        if drivesItself {
            let timer = Timer(timeInterval: LivingGarden.tick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step(simTime: CACurrentMediaTime() - (self?.epoch ?? 0)) }
            }
            timer.tolerance = 0.4
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    // MARK: One growth step

    /// Advances the garden to `t` seconds on its own clock and animates whatever started.
    func step(simTime t: Double) {
        guard let model, isRunning else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let changes = model.advanceLiving(to: t)
        process(changes, at: t, animated: true)
        // Settle every other step, so a tile is redrawn once for two steps' worth of new cells.
        stepIndex += 1
        if stepIndex % 2 == 0 || !changes.withered.isEmpty { settle(at: t) }
        flush(limit: 2)
        expireTransients(at: t)
        CATransaction.commit()
        if t - lastFrost >= Self.frostRefresh { lastFrost = t; frostIsStale?() }
    }

    private func process(_ changes: LivingGarden.Changes, at t: Double, animated: Bool) {
        guard let model, let look, let living = model.living else { return }
        let field = living.field
        let w = field.cellWidth, h = field.cellHeight
        let columns = field.columns
        func drawable(_ cell: VineCell) -> Bool { Double(cell.y) * h >= Double(look.clearing) }
        for born in changes.born where drawable(born.cell) {
            let key = VineField.key(born.cell.x, born.cell.y, columns: columns)
            // A catch-up draws the cell straight into its tile; otherwise its own layer fades in first.
            guard animated else { dirtyTile(for: born.cell); continue }
            pending[key] = born.at
            cellLayers[key]?.removeFromSuperlayer()
            let layer = growingCell(born.cell, palette: look.palette, w: w, h: h)
            live.addSublayer(layer)
            cellLayers[key] = layer
            if born.cell.kind == .bloom { addPop(for: born.cell, palette: look.palette, w: w, h: h, at: born.at, now: t) }
        }
        for withered in changes.withered where drawable(withered.cell) {
            let cell = withered.cell
            let key = VineField.key(cell.x, cell.y, columns: columns)
            dirtyTile(for: cell)
            pending[key] = nil
            cellLayers[key]?.removeFromSuperlayer(); cellLayers[key] = nil
            guard animated else { continue }
            addWithering(cell, palette: look.palette, w: w, h: h, delay: max(0, withered.at - t), until: withered.at + LivingGarden.witherFade + 0.3)
        }
        guard animated else { return }
        for spores in changes.spores where drawable(spores.cell) {
            addSpores(spores.cell, palette: look.palette, w: w, h: h, delay: max(0, spores.at - t), now: t)
        }
        for petal in changes.petals { addPetal(petal, palette: look.palette, delay: max(0, petal.at - t), now: t) }
        updateHeads(field: field, palette: look.palette, w: w, h: h)
    }

    /// Moves cells that finished fading in from their own layers into the tiles.
    private func settle(at t: Double) {
        for (key, born) in pending where t - born >= Self.settleAfter {
            pending[key] = nil
            cellLayers[key]?.removeFromSuperlayer(); cellLayers[key] = nil
            dirtyTile(forKey: key)
        }
    }

    // MARK: Tiles

    private func tileID(x: Int, y: Int, w: Double, h: Double) -> TileID {
        TileID(x: Int((Double(x) * w / Double(Self.tileSize)).rounded(.down)), y: Int((Double(y) * h / Double(Self.tileSize)).rounded(.down)))
    }

    private func dirtyTile(for cell: VineCell) {
        guard let field = model?.living?.field else { return }
        dirty.insert(tileID(x: cell.x, y: cell.y, w: field.cellWidth, h: field.cellHeight))
    }

    private func dirtyTile(forKey key: Int) {
        guard let field = model?.living?.field else { return }
        dirty.insert(tileID(x: key % field.columns, y: key / field.columns, w: field.cellWidth, h: field.cellHeight))
    }

    /// Redraws the tiles whose cells changed, at most `limit` of them (all of them when nil).
    /// A branch withering across many tiles is spread over a few steps rather than one long one.
    func flush(limit: Int? = nil) {
        guard !dirty.isEmpty, let model, let look, let field = model.living?.field else { return }
        let w = field.cellWidth, h = field.cellHeight
        let ids = Array(dirty.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.prefix(limit ?? dirty.count))
        let chosen = Set(ids)
        var buckets: [TileID: [VineCell]] = [:]
        for (key, cell) in field.cells where Double(cell.y) * h >= Double(look.clearing) && pending[key] == nil {
            let id = tileID(x: cell.x, y: cell.y, w: w, h: h)
            if chosen.contains(id) { buckets[id, default: []].append(cell) }
        }
        for id in ids {
            dirty.remove(id)
            let cells = buckets[id] ?? []
            if cells.isEmpty, tiles[id] == nil { continue }
            let tile = tiles[id] ?? makeTile(id)
            let images = Self.drawTile(id, cells: cells, palette: look.palette, scale: look.scale, cellWidth: w, cellHeight: h)
            tile.base.contents = images.base
            tile.still.contents = images.still
            tile.flutter.contents = images.flutter
        }
    }

    private func makeTile(_ id: TileID) -> Tile {
        let tile = Tile()
        let side = Self.tileSize + Self.tileBleed
        let height = canvasHeight
        for (layer, parent) in [(tile.base, base), (tile.still, still), (tile.flutter, flutter)] {
            layer.anchorPoint = .zero
            layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            layer.position = CGPoint(x: CGFloat(id.x) * Self.tileSize, y: height - CGFloat(id.y) * Self.tileSize - side)
            layer.contentsScale = look?.scale ?? 2
            layer.contentsGravity = .topLeft
            parent.addSublayer(layer)
        }
        tiles[id] = tile
        return tile
    }

    private var canvasHeight: CGFloat { look?.size.height ?? 0 }

    /// Draws one tile's three layers: stems; leaves and blooms at rest; the same blown aside.
    /// Glyph bitmaps go down at their own pixel size, so nothing is resampled.
    private static func drawTile(_ id: TileID, cells: [VineCell], palette: VinePalette, scale: CGFloat,
                                 cellWidth w: Double, cellHeight h: Double) -> (base: CGImage?, still: CGImage?, flutter: CGImage?) {
        let side = tileSize + tileBleed
        let pixels = Int((side * scale).rounded(.up))
        // The glyph bitmaps are device RGB; drawing them into the same space skips a conversion per glyph.
        let space = CGColorSpaceCreateDeviceRGB()
        var contexts: [CGContext?] = [nil, nil, nil]
        func context(_ index: Int) -> CGContext? {
            if let existing = contexts[index] { return existing }
            let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            cg?.scaleBy(x: scale, y: scale)
            cg?.interpolationQuality = .none
            contexts[index] = cg
            return cg
        }
        let originX = Double(id.x) * Double(tileSize), originY = Double(id.y) * Double(tileSize)
        func draw(_ cell: VineCell, _ glyph: Character, dx: Double, into index: Int) {
            guard let image = GlyphAtlas.cgImage(glyph, palette.color(cell.kind, slot: cell.slot), scale: scale), let cg = context(index) else { return }
            let width = Double(image.width) / Double(scale), height = Double(image.height) / Double(scale)
            // Whole device pixels, so the bitmap is copied, not resampled.
            let x = ((Double(cell.x) * w - originX + dx) * Double(scale)).rounded() / Double(scale)
            let yTop = ((Double(cell.y) * h - originY) * Double(scale)).rounded() / Double(scale)
            cg.setAlpha(restingAlpha(cell, palette))
            cg.draw(image, in: CGRect(x: x, y: Double(side) - yTop - height, width: width, height: height))
        }
        for cell in cells {
            switch cell.kind {
            case .stem:
                draw(cell, cell.glyph, dx: 0, into: 0)
            case .leaf:
                draw(cell, cell.glyph, dx: 0, into: 1)
                draw(cell, cell.alternate ?? cell.glyph, dx: w * 0.3, into: 2)
            case .bloom:
                draw(cell, cell.glyph, dx: 0, into: 1)
                draw(cell, cell.glyph, dx: w * 0.18, into: 2)
            }
        }
        return (contexts[0]?.makeImage(), contexts[1]?.makeImage(), contexts[2]?.makeImage())
    }

    static func restingAlpha(_ cell: VineCell, _ palette: VinePalette) -> Double {
        min(1, palette.baseAlpha * (cell.kind == .stem ? 0.9 : 1) * 0.92)
    }

    // MARK: Rebuilding

    private func rebuild(_ next: Look) {
        stopTimerOnly()
        isRunning = false
        look = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for container in [base, still, flutter, live, flies] { container.sublayers?.forEach { $0.removeFromSuperlayer() } }
        still.mask = nil; flutter.mask = nil; layer?.mask = nil
        tiles = [:]; dirty = []; pending = [:]; cellLayers = [:]; headLayers = [:]; transient = []
        canvas.bounds = CGRect(origin: .zero, size: next.size)
        for container in [base, still, flutter, live, flies] { container.bounds = canvas.bounds; container.position = .zero }
        placeCanvas()
        guard let model else { CATransaction.commit(); return }
        if next.frozenAt != nil { model.restartLiving() } else { model.beginLiving() }
        guard let living = model.living else { CATransaction.commit(); return }
        if let frozen = next.frozenAt {
            // A single frame at a fixed moment, drawn from the same functions the animations are sampled from.
            let changes = model.advanceLiving(to: frozen)
            process(changes, at: frozen, animated: false)
            markAllDirty()
            flush()
            installWind(frozenAt: frozen)
            buildFireflies(frozenAt: frozen)
            addStaticMoment(changes, at: frozen)
        } else {
            epoch = CACurrentMediaTime() - living.time
            markAllDirty()
            flush()
            installWind(frozenAt: nil, animated: false)
        }
        CATransaction.commit()
    }

    private func stopTimerOnly() { timer?.invalidate(); timer = nil }

    private func markAllDirty() {
        guard let field = model?.living?.field, let look else { return }
        for cell in field.cells.values where Double(cell.y) * field.cellHeight >= Double(look.clearing) { dirtyTile(for: cell) }
    }

    // MARK: Wind

    private func installWind(frozenAt: Double?, animated: Bool = true) {
        guard let look else { return }
        let wind = GardenWind(width: Double(look.size.width))
        let height = look.size.height
        func gradient(width: Double, stops: [(Double, Double)]) -> CAGradientLayer {
            let mask = CAGradientLayer()
            mask.colors = stops.map { CGColor(gray: 1, alpha: $0.1) }
            mask.locations = stops.map { NSNumber(value: $0.0) }
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            return mask
        }
        // A smooth bump, sampled so the gradient follows the same curve as `GardenWind.strength`.
        let samples = stride(from: 0.0, through: 1.0, by: 0.125).map { u -> (Double, Double) in
            (u, wind.strength(at: u * wind.bandWidth, centre: wind.bandWidth / 2))
        }
        let flutterMask = gradient(width: wind.bandWidth, stops: samples)
        // The still leaves show wherever the band is not: solid beyond it, a dip through it.
        let span = Double(look.size.width) * 2 + wind.bandWidth
        let lead = Double(look.size.width) / span, bump = wind.bandWidth / span
        var inverse: [(Double, Double)] = [(0, 1), (lead, 1)]
        for (u, strength) in samples.dropFirst().dropLast() { inverse.append((lead + u * bump, 1 - strength)) }
        inverse += [(lead + bump, 1), (1, 1)]
        let stillMask = gradient(width: span, stops: inverse)
        let initial = frozenAt.map { wind.centre(at: $0) } ?? -wind.bandWidth / 2
        for mask in [flutterMask, stillMask] { mask.position = CGPoint(x: initial, y: height / 2) }
        still.mask = stillMask
        flutter.mask = flutterMask
        guard animated, frozenAt == nil else { return }
        let sweep = CAKeyframeAnimation(keyPath: "position.x")
        sweep.values = [-wind.bandWidth / 2, wind.width + wind.bandWidth / 2, wind.width + wind.bandWidth / 2]
        sweep.keyTimes = [0, NSNumber(value: wind.crossing / wind.period), 1]
        sweep.duration = wind.period
        sweep.repeatCount = .infinity
        sweep.calculationMode = .linear
        // The first band arrives a few seconds in, not after a whole rest.
        sweep.timeOffset = max(0, wind.period - 4)
        for mask in [flutterMask, stillMask] { mask.add(sweep, forKey: Self.windKey) }
    }

    /// The same soft band of light as the settled garden's breathing, kept here for the root layer.
    static func breathingBand(width: CGFloat, height: CGFloat) -> CALayer {
        BreathingBand.make(width: width, height: height)
    }

    // MARK: Cells

    private func glyphLayer(_ glyph: Character, hex: UInt32, w: Double, h: Double) -> CALayer {
        let scale = look?.scale ?? 2
        let image = GlyphAtlas.cgImage(glyph, hex, scale: scale)
        let layer = CALayer()
        layer.anchorPoint = .zero
        // The bitmap's own size in points, so it is never resampled.
        layer.bounds = CGRect(x: 0, y: 0, width: image.map { Double($0.width) / Double(scale) } ?? w * 1.6,
                              height: image.map { Double($0.height) / Double(scale) } ?? h)
        layer.contentsScale = scale
        layer.contents = image
        return layer
    }

    private func place(_ layer: CALayer, x: Double, y: Double) {
        layer.position = CGPoint(x: x, y: Double(canvasHeight) - y - Double(layer.bounds.height))
    }

    private func growingCell(_ cell: VineCell, palette: VinePalette, w: Double, h: Double) -> CALayer {
        let layer = glyphLayer(cell.glyph, hex: palette.color(cell.kind, slot: cell.slot), w: w, h: h)
        place(layer, x: Double(cell.x) * w, y: Double(cell.y) * h)
        let alpha = Float(Self.restingAlpha(cell, palette))
        layer.opacity = alpha
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = alpha
        fade.duration = LivingGarden.fadeIn
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "fade")
        return layer
    }

    /// A new bloom flashes as it opens: a faint copy lifts away and fades.
    private func addPop(for cell: VineCell, palette: VinePalette, w: Double, h: Double, at born: Double, now: Double) {
        let layer = glyphLayer(cell.glyph, hex: palette.color(cell.kind, slot: cell.slot), w: w, h: h)
        let x = Double(cell.x) * w, y = Double(cell.y) * h
        place(layer, x: x, y: y)
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.6; fade.toValue = 0
        fade.duration = 0.9
        let lift = CABasicAnimation(keyPath: "position.y")
        lift.fromValue = layer.position.y; lift.toValue = layer.position.y + 2
        lift.duration = 0.9
        layer.add(group([fade, lift], duration: 0.9), forKey: "pop")
        live.addSublayer(layer)
        transient.append((layer, now + 1.2))
    }

    /// A branch letting go: the cell stays where it was and fades, starting when its turn comes.
    private func addWithering(_ cell: VineCell, palette: VinePalette, w: Double, h: Double, delay: Double, until: Double) {
        let layer = glyphLayer(cell.glyph, hex: palette.color(cell.kind, slot: cell.slot), w: w, h: h)
        place(layer, x: Double(cell.x) * w, y: Double(cell.y) * h)
        let alpha = Float(Self.restingAlpha(cell, palette))
        layer.opacity = alpha
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = alpha; fade.toValue = 0
        fade.duration = LivingGarden.witherFade
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "wither")
        live.addSublayer(layer)
        transient.append((layer, until))
    }

    // MARK: Spores and petals

    /// Layers for a flight sampled every `every` seconds: position, opacity and, optionally, glyph.
    private func addFlight(_ layer: CALayer, life: Double, delay: Double, every: Double, now: Double,
                           point: (Double) -> CGPoint, alpha: (Double) -> Double, glyphs: ((Double) -> CGImage?)? = nil, snapshotAge: Double? = nil) {
        guard let look else { return }
        let h = Double(look.size.height)
        let count = Int((life / every).rounded(.up)) + 1
        let ages = (0..<count).map { min(life, Double($0) * every) }
        func position(_ age: Double) -> CGPoint {
            let p = point(age)
            return CGPoint(x: p.x, y: h - p.y - Double(layer.bounds.height))
        }
        if let age = snapshotAge {
            layer.position = position(age)
            layer.opacity = Float(alpha(age))
            if let glyphs { layer.contents = glyphs(age) }
            live.addSublayer(layer)
            return
        }
        layer.position = position(0)
        layer.opacity = 0
        let begin = CACurrentMediaTime() + delay
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = ages.map { NSValue(point: position($0)) }
        move.keyTimes = ages.map { NSNumber(value: $0 / life) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = ages.map { Float(alpha($0)) }
        fade.keyTimes = move.keyTimes
        var animations: [CAAnimation] = [move, fade]
        if let glyphs {
            let tumble = CAKeyframeAnimation(keyPath: "contents")
            tumble.values = ages.map { glyphs($0) as Any }
            tumble.keyTimes = move.keyTimes
            tumble.calculationMode = .discrete
            animations.append(tumble)
        }
        let flight = group(animations, duration: life)
        flight.beginTime = begin
        flight.fillMode = .both
        layer.add(flight, forKey: Self.flightKey)
        live.addSublayer(layer)
        transient.append((layer, (model?.livingTime ?? now) + delay + life + 0.3))
    }

    private func group(_ animations: [CAAnimation], duration: Double) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.isRemovedOnCompletion = true
        return group
    }

    private func addSpores(_ cell: VineCell, palette: VinePalette, w: Double, h: Double, delay: Double, now: Double, snapshotAge: Double? = nil) {
        guard let layout = model?.layout else { return }
        for flight in GardenSpores.flights(from: cell, cellWidth: w, cellHeight: h) {
            if let age = snapshotAge, age >= flight.life { continue }
            let layer = glyphLayer(flight.glyph, hex: palette.leaves[1], w: w, h: h)
            addFlight(layer, life: flight.life, delay: delay, every: 0.4, now: now,
                      point: { age in flight.point(age: age) },
                      alpha: { age in
                          let p = flight.point(age: age)
                          return GardenSpores.isClear(x: p.x, y: p.y, layout: layout, cellWidth: w, cellHeight: h) ? flight.alpha(age: age) : 0
                      }, snapshotAge: snapshotAge)
        }
    }

    private func addPetal(_ petal: LivingGarden.Petal, palette: VinePalette, delay: Double, now: Double, snapshotAge: Double? = nil) {
        guard let layout = model?.layout, let field = model?.living?.field, let look else { return }
        let w = field.cellWidth, h = field.cellHeight
        let hex = palette.blooms[petal.colour % palette.blooms.count]
        let layer = glyphLayer(LivingGarden.Petal.glyphs[0], hex: hex, w: w, h: h)
        addFlight(layer, life: petal.life, delay: delay, every: LivingGarden.Petal.tumble / 2, now: now,
                  point: { age in
                      let p = petal.position(age: age)
                      return CGPoint(x: p.x, y: p.y)
                  },
                  alpha: { age in
                      let p = petal.position(age: age)
                      return GardenSpores.isClear(x: p.x, y: p.y, layout: layout, cellWidth: w, cellHeight: h) ? petal.alpha(age: age) : 0
                  },
                  glyphs: { age in GlyphAtlas.cgImage(petal.glyph(age: age), hex, scale: look.scale) },
                  snapshotAge: snapshotAge)
    }

    // MARK: Growing tips

    private func updateHeads(field: VineField, palette: VinePalette, w: Double, h: Double) {
        let tips = field.activeHeads
        let live = Set(tips.map(\.branch))
        for (branch, layer) in headLayers where !live.contains(branch) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity; fade.toValue = 0; fade.duration = 0.5
            layer.opacity = 0
            layer.add(fade, forKey: "fade")
            headLayers[branch] = nil
            transient.append((layer, (model?.livingTime ?? 0) + 0.8))
        }
        for tip in tips {
            let x = tip.point.x - w * 0.5, y = tip.point.y - h * 0.55
            if let head = headLayers[tip.branch] {
                let from = head.position
                place(head, x: x, y: y)
                let glide = CABasicAnimation(keyPath: "position")
                glide.fromValue = NSValue(point: from); glide.toValue = NSValue(point: head.position)
                glide.duration = LivingGarden.tick
                head.add(glide, forKey: "glide")
            } else {
                let head = glyphLayer("•", hex: palette.head, w: w, h: h)
                place(head, x: x, y: y)
                head.opacity = 0.85
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0; fade.toValue = 0.85; fade.duration = 0.5
                head.add(fade, forKey: "fade")
                self.live.addSublayer(head)
                headLayers[tip.branch] = head
            }
        }
    }

    private func clearTransients() {
        for item in transient { item.layer.removeFromSuperlayer() }
        transient = []
        for layer in cellLayers.values { layer.removeFromSuperlayer() }
        cellLayers = [:]
        for layer in headLayers.values { layer.removeFromSuperlayer() }
        headLayers = [:]
    }

    private func expireTransients(at t: Double) {
        guard transient.contains(where: { $0.until <= t }) else { return }
        for item in transient where item.until <= t { item.layer.removeFromSuperlayer() }
        transient.removeAll { $0.until <= t }
    }

    // MARK: Fireflies

    private func isFree(_ point: CGPoint) -> Bool {
        guard let look, let layout = model?.layout else { return false }
        let inset: CGFloat = 4
        guard point.x >= inset, point.y >= max(inset, look.clearing + 8), point.x <= look.size.width - inset, point.y <= look.size.height - inset else { return false }
        for rect in layout.avoid where rect.insetBy(dx: -16, dy: -16).contains(point) { return false }
        for rect in keepOut where rect.insetBy(dx: -6, dy: -6).contains(point) { return false }
        return true
    }

    private func buildFireflies(frozenAt: Double?) {
        flies.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let look, look.fireflies > 0, let layout = model?.layout else { return }
        let sprite = Self.fireflySprite(dark: look.dark, scale: look.scale)
        let side = look.dark ? 46.0 : 26.0
        let height = Double(look.size.height)
        for index in 0..<look.fireflies {
            guard let track = FireflyTrack.make(index: index, seed: layout.seed, size: look.size, dark: look.dark, isFree: { [self] in isFree($0) }) else { continue }
            let outer = CALayer()
            outer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            let core = CALayer()
            core.frame = outer.bounds
            core.contents = sprite
            core.contentsScale = look.scale
            outer.addSublayer(core)
            func centre(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }
            if let t = frozenAt {
                outer.position = centre(track.position(at: t))
                core.opacity = Float(track.blink(at: t))
            } else {
                outer.position = centre(track.points[0])
                let drift = CAKeyframeAnimation(keyPath: "position")
                drift.values = track.points.map { NSValue(point: centre($0)) }
                drift.calculationMode = .cubic
                drift.duration = track.duration
                drift.autoreverses = true
                drift.repeatCount = .infinity
                outer.add(drift, forKey: Self.flightKey)
                let cycle = 2 * Double.pi / track.omega
                let blink = CAKeyframeAnimation(keyPath: "opacity")
                blink.values = (0...16).map { Float(track.blink(at: Double($0) / 16 * cycle)) }
                blink.duration = cycle
                blink.repeatCount = .infinity
                core.opacity = Float(track.blink(at: 0))
                core.add(blink, forKey: Self.blinkKey)
            }
            flies.addSublayer(outer)
        }
    }

    /// A soft glow with a bright core, drawn once per appearance.
    static func fireflySprite(dark: Bool, scale: CGFloat) -> CGImage? {
        let side = dark ? 46.0 : 26.0
        let pixels = Int((side * scale).rounded(.up))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.scaleBy(x: scale, y: scale)
        let glow = dark ? (0.90, 0.96, 0.60) : (0.77, 0.54, 0.07)
        let strength = dark ? 0.8 : 0.5
        func colour(_ alpha: Double) -> CGColor { CGColor(srgbRed: glow.0, green: glow.1, blue: glow.2, alpha: alpha * strength) }
        let gradient = CGGradient(colorsSpace: space, colors: [colour(0.95), colour(0.45), colour(0.12), colour(0)] as CFArray, locations: [0, 0.18, 0.5, 1])
        let centre = CGPoint(x: side / 2, y: side / 2)
        if let gradient { cg.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: side / 2, options: []) }
        let radius = dark ? 1.8 : 1.5
        cg.setFillColor(dark ? CGColor(srgbRed: 0.98, green: 1, blue: 0.88, alpha: 1) : CGColor(srgbRed: glow.0, green: glow.1, blue: glow.2, alpha: 1))
        cg.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        return cg.makeImage()
    }

    // MARK: Keep-out rectangles

    private func frostRegionsChanged() {
        keepOutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.updateKeepOut() } }
        keepOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Glass hides the sharp garden, so fireflies keep to the open gaps around it.
    private func updateKeepOut() {
        let rects = (frost?.regions ?? []).map { $0.frame.offsetBy(dx: 0, dy: frostOffset) }
        guard rects != keepOut else { return }
        keepOut = rects
        guard let look, isRunning || look.frozenAt != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        buildFireflies(frozenAt: look.frozenAt)
        CATransaction.commit()
    }

    // MARK: A single frame at a fixed moment

    /// Everything that is mid-flight at `t`, as still layers: what a screenshot would catch.
    private func addStaticMoment(_ changes: LivingGarden.Changes, at t: Double) {
        guard let look, let field = model?.living?.field else { return }
        let w = field.cellWidth, h = field.cellHeight
        for withered in changes.withered where withered.at + LivingGarden.witherFade > t && Double(withered.cell.y) * h >= Double(look.clearing) {
            let cell = withered.cell
            let layer = glyphLayer(cell.glyph, hex: look.palette.color(cell.kind, slot: cell.slot), w: w, h: h)
            place(layer, x: Double(cell.x) * w, y: Double(cell.y) * h)
            let fade = 1 - smoothstep(withered.at, withered.at + LivingGarden.witherFade, t)
            layer.opacity = Float(Self.restingAlpha(cell, look.palette) * fade)
            live.addSublayer(layer)
        }
        for spores in changes.spores where t - spores.at < 10 && t >= spores.at && Double(spores.cell.y) * h >= Double(look.clearing) {
            addSpores(spores.cell, palette: look.palette, w: w, h: h, delay: 0, now: t, snapshotAge: t - spores.at)
        }
        for petal in changes.petals where t - petal.at < petal.life {
            addPetal(petal, palette: look.palette, delay: 0, now: t, snapshotAge: t - petal.at)
        }
        for tip in field.activeHeads {
            let head = glyphLayer("•", hex: look.palette.head, w: w, h: h)
            place(head, x: tip.point.x - w * 0.5, y: tip.point.y - h * 0.55)
            head.opacity = 0.85
            live.addSublayer(head)
        }
    }
}

/// The slow band of light that moves across a grown garden, run by the render server.
enum BreathingBand {
    /// The mask is a gradient three garden-widths wide whose centre travels from just left of the
    /// garden to beyond its right edge, so the garden's brightness drifts between 74% and 100%.
    static func make(width: CGFloat, height: CGFloat) -> CAGradientLayer {
        let band = CAGradientLayer()
        band.colors = [0.74, 1, 0.74].map { CGColor(gray: 1, alpha: $0) }
        band.locations = [0, 0.5, 1]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.bounds = CGRect(x: 0, y: 0, width: width * 3, height: height)
        band.position = CGPoint(x: width / 2, y: height / 2)
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = NSNumber(value: Double(-width / 2))
        sweep.toValue = NSNumber(value: Double(width * 1.5))
        sweep.duration = GardenStillView.breathePeriod
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        band.add(sweep, forKey: GardenStillView.breatheKey)
        return band
    }
}

/// Presents the living garden inside SwiftUI.
struct LivingGardenLayer: NSViewRepresentable {
    let model: GardenModel
    let palette: VinePalette
    let dark: Bool
    let scale: CGFloat
    let active: Bool
    let frost: FrostRegions?
    let frostOffset: CGFloat
    let frozenAt: Double?
    let onFrostStale: () -> Void

    func makeNSView(context: Context) -> LivingGardenView { LivingGardenView(frame: .zero) }

    func updateNSView(_ view: LivingGardenView, context: Context) {
        view.frostIsStale = onFrostStale
        view.apply(model: model, palette: palette, dark: dark, scale: scale, active: active, frost: frost, frostOffset: frostOffset, frozenAt: frozenAt)
    }
}

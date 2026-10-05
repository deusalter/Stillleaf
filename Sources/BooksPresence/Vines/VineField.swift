import Foundation

/// A position in grid cells (paths) or points (heads).
struct VinePoint: Equatable {
    var x: Double
    var y: Double
}

/// Later kinds win a cell: a leaf may replace a stem, a bloom either.
enum VineKind: Int {
    case stem = 1, leaf, bloom
}

struct VineCell: Equatable {
    let x: Int
    let y: Int
    let glyph: Character
    /// The leaf shape it cross-fades to when the breathing wave passes.
    let alternate: Character?
    let kind: VineKind
    /// Index into the palette colours for its kind.
    let slot: Int
    /// The growth step that placed it, so the renderer can fade it in on time.
    let step: Int
    let phase: Double
}

enum VineGlyphs {
    static let leaves: [(Character, Character)] = [("(", ")"), ("{", "}"), ("6", "9"), ("@", "@"), ("o", "o"), ("(", ")")]
    static let flutter: [Character: Character] = ["(": "{", ")": "}", "{": "(", "}": ")", "6": "(", "9": ")", "@": "o", "o": "@"]
    static let blooms: [Character] = ["✿", "❀", "✽", "*", "❁", "✻"]
    static let pollen: [Character] = [".", "·", ":", "˙", "'", "`", ",", "·"]

    /// The stem glyph for a step of (dx, dy) points; screen y grows downward.
    static func stem(dx: Double, dy: Double) -> Character {
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 180 }
        if degrees < 22.5 || degrees >= 157.5 { return "─" }
        if degrees < 67.5 { return "╲" }
        if degrees < 112.5 { return "│" }
        return "╱"
    }
}

struct VineTipSpec {
    var x: Int
    var y: Int
    var heading = -Double.pi / 2
    var life = 40
    var generation = 0
    var bias: Double? = nil
    var biasStrength = 0.06
    var curl = 0.0
    var hue = 0
    var branchChance = 0.06
    var leafChance = 0.24
    var bloomChance = 0.75
    var maxGeneration = 3
    var branchLife = 14
    /// Grid-cell points to follow instead of wandering.
    var path: [VinePoint]? = nil
    var wobble = 0.0
    var wobbleFrequency = 0.33
    /// Branches of a path follower grow toward this heading.
    var outward: Double? = nil
}

/// Seeds that keep a garden stable for a day and change it the next.
enum GardenSeed {
    static func daily(_ kind: String, day: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in "\(kind)|\(day)".utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }
}

/// Deterministic xorshift32; the reader's JavaScript port uses the same sequence.
struct VineRandom {
    private var state: UInt32
    init(seed: UInt32) { state = seed == 0 ? 7 : seed }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Double(state) / 4_294_967_296
    }
}

/// The vine model: tips that wander or follow paths across a character grid,
/// leaving stems, leaves and blooms. Pure and deterministic, so the renderer,
/// tests and offscreen previews all see the same garden for the same seed.
struct VineField {
    let columns: Int
    let rows: Int
    let cellWidth: Double
    let cellHeight: Double
    let maxCells: Int
    var maxTips = 60
    /// Growth stops once this many cells exist; raising it resumes growth.
    var budget = Int.max
    /// Cells a vine may occupy. Refused cells turn wandering tips aside.
    var allows: (Int, Int) -> Bool = { _, _ in true }
    private(set) var cells: [Int: VineCell] = [:]
    private(set) var stepCount = 0
    private var tips: [Tip] = []
    private var random: VineRandom

    private struct Tip {
        var spec: VineTipSpec
        var px: Double
        var py: Double
        var heading: Double
        var drift = 0.0
        var life: Int
        var lastX: Int
        var lastY: Int
        var index = 0
        let phase: Double
    }

    init(columns: Int, rows: Int, cellWidth: Double, cellHeight: Double, seed: UInt32, maxCells: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.maxCells = maxCells
        random = VineRandom(seed: seed &* 9973 &+ 17)
    }

    static func key(_ x: Int, _ y: Int, columns: Int) -> Int { y * columns + x }

    var isGrowing: Bool { !tips.isEmpty && cells.count < budget }

    /// Live tip positions in points, for the gliding heads.
    var heads: [VinePoint] { tips.map { VinePoint(x: $0.px, y: $0.py) } }

    mutating func plant(_ spec: VineTipSpec) {
        tips.append(Tip(spec: spec, px: (Double(spec.x) + 0.5) * cellWidth, py: (Double(spec.y) + 0.5) * cellHeight,
                        heading: spec.heading, life: spec.life, lastX: spec.x, lastY: spec.y, phase: random.next() * 2 * .pi))
    }

    /// Advances every tip by one cell.
    mutating func step() {
        guard cells.count < budget else { return }
        for index in stride(from: tips.count - 1, through: 0, by: -1) {
            if tips[index].life > 0 {
                if tips[index].spec.path == nil { wander(index) } else { follow(index) }
            }
            if tips[index].life <= 0 {
                finish(tips[index])
                tips.remove(at: index)
            }
        }
        stepCount += 1
    }

    mutating func growToCompletion(limit: Int = 10_000) {
        var steps = 0
        while isGrowing && steps < limit { step(); steps += 1 }
    }

    // MARK: Growth

    private mutating func wander(_ index: Int) {
        var tip = tips[index]
        defer { tips[index] = tip }
        tip.drift = tip.drift * 0.82 + (random.next() - 0.5) * 0.42
        tip.heading += tip.drift
        if let bias = tip.spec.bias { tip.heading += Self.angleDifference(bias, tip.heading) * tip.spec.biasStrength }
        tip.heading += tip.spec.curl
        var moved = false
        for _ in 0..<3 where !moved {
            // Exactly one cell along the dominant axis, so stems never leave gaps.
            let length = 0.999 / max(abs(cos(tip.heading)) / cellWidth, abs(sin(tip.heading)) / cellHeight)
            let nx = tip.px + cos(tip.heading) * length, ny = tip.py + sin(tip.heading) * length
            let cx = Int((nx / cellWidth).rounded(.down)), cy = Int((ny / cellHeight).rounded(.down))
            guard permits(cx, cy) else {
                tip.heading += (random.next() < 0.5 ? -1 : 1) * (0.7 + random.next() * 0.6)
                continue
            }
            let dx = nx - tip.px, dy = ny - tip.py
            tip.px = nx; tip.py = ny; moved = true
            if cx == tip.lastX && cy == tip.lastY { return }
            var glyph = VineGlyphs.stem(dx: dx, dy: dy)
            if tip.spec.generation >= 2 && abs(tip.drift) > 0.32 { glyph = tip.drift > 0 ? ")" : "(" }
            else if tip.spec.generation >= 2 && glyph == "─" { glyph = "~" }
            put(cx, cy, glyph, .stem, slot: (tip.spec.generation + tip.spec.hue) % 4)
            tips[index] = tip
            sprout(from: tip, x: cx, y: cy, dx: dx, dy: dy)
            tip.lastX = cx; tip.lastY = cy
        }
        if !moved { tip.life = 0 }
        tip.life -= 1
    }

    private mutating func follow(_ index: Int) {
        var tip = tips[index]
        defer { tips[index] = tip }
        guard let path = tip.spec.path, tip.index < path.count - 1 else { tip.life = 0; return }
        var placed = false
        while !placed && tip.index < path.count - 1 {
            tip.index += 1
            let a = path[tip.index - 1], b = path[tip.index]
            let tx = b.x - a.x, ty = b.y - a.y, length = max(hypot(tx, ty), .ulpOfOne)
            let offset = tip.spec.wobble * sin(Double(tip.index) * tip.spec.wobbleFrequency + tip.phase)
            let fx = b.x - ty / length * offset, fy = b.y + tx / length * offset * 0.6
            let cx = Int(fx.rounded()), cy = Int(fy.rounded())
            tip.px = (fx + 0.5) * cellWidth; tip.py = (fy + 0.5) * cellHeight
            if cx == tip.lastX && cy == tip.lastY { continue }
            let dx = Double(cx - tip.lastX) * cellWidth, dy = Double(cy - tip.lastY) * cellHeight
            put(cx, cy, VineGlyphs.stem(dx: dx, dy: dy), .stem, slot: tip.spec.hue % 4)
            tips[index] = tip
            sprout(from: tip, x: cx, y: cy, dx: dx, dy: dy)
            tip.lastX = cx; tip.lastY = cy
            placed = true
        }
        if tip.index >= path.count - 1 { tip.life = 0 }
    }

    private mutating func sprout(from tip: Tip, x: Int, y: Int, dx: Double, dy: Double) {
        let spec = tip.spec
        if random.next() < spec.leafChance * (spec.generation > 1 ? 0.7 : 1) {
            let vertical = abs(dy) > abs(dx) * 0.6
            let side = random.next() < 0.5 ? -1 : 1
            let pair = VineGlyphs.leaves[Int(random.next() * Double(VineGlyphs.leaves.count))]
            let glyph = vertical ? (side < 0 ? pair.0 : pair.1) : (random.next() < 0.5 ? pair.0 : pair.1)
            put(vertical ? x + side : x, vertical ? y : y + side, glyph, .leaf, slot: Int(random.next() * 5))
        }
        if spec.generation < spec.maxGeneration && random.next() < spec.branchChance && tips.count < maxTips {
            var heading = atan2(dy, dx) + (random.next() < 0.5 ? -1 : 1) * (0.55 + random.next() * 0.65)
            if let outward = spec.outward { heading = outward + (random.next() - 0.5) * 0.9 }
            var branch = VineTipSpec(x: x, y: y)
            branch.heading = heading
            branch.life = Int(Double(spec.branchLife) * (0.4 + random.next() * 0.8))
            branch.generation = spec.generation + 1
            branch.bias = spec.path == nil ? spec.bias : nil
            branch.biasStrength = spec.biasStrength * 0.6
            branch.hue = spec.hue + 1
            branch.branchChance = spec.branchChance * 0.7
            branch.leafChance = spec.leafChance
            branch.bloomChance = spec.bloomChance
            branch.maxGeneration = spec.maxGeneration
            branch.branchLife = spec.branchLife
            branch.curl = (random.next() - 0.5) * 0.08
            plant(branch)
        }
    }

    private mutating func finish(_ tip: Tip) {
        guard random.next() < tip.spec.bloomChance else { return }
        let glyph = VineGlyphs.blooms[Int(random.next() * Double(VineGlyphs.blooms.count))]
        put(tip.lastX + Int(cos(tip.heading).rounded()), tip.lastY + Int(sin(tip.heading).rounded()), glyph, .bloom, slot: Int(random.next() * 4))
    }

    private func permits(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < columns && y < rows && allows(x, y)
    }

    @discardableResult
    private mutating func put(_ x: Int, _ y: Int, _ glyph: Character, _ kind: VineKind, slot: Int) -> Bool {
        guard permits(x, y), cells.count < maxCells else { return false }
        let key = Self.key(x, y, columns: columns)
        if let existing = cells[key], existing.kind.rawValue >= kind.rawValue { return false }
        cells[key] = VineCell(x: x, y: y, glyph: glyph, alternate: kind == .leaf ? VineGlyphs.flutter[glyph] : nil,
                              kind: kind, slot: slot, step: stepCount, phase: random.next() * 2 * .pi)
        return true
    }

    private static func angleDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }
}

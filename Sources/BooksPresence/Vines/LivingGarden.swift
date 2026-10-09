import Foundation

/// A grown garden that keeps living: new shoots grow slowly from old stems, the oldest branches
/// wither away so the density holds steady, blooms shed petals, and withering leaves let go of
/// spores. Pure and deterministic, so tests, offscreen renders and the live view agree: the same
/// seed and the same clock give the same garden. The view animates what `advance` reports and
/// owns nothing of the model.
struct LivingGarden {
    /// Seconds per growth step: a shoot grows about one cell every 1.5 s.
    static let tick = 1.5
    /// A new cell fades in over this long.
    static let fadeIn = 0.7
    /// A branch withers from its tip back to its stem over about this long.
    static let witherSpan = 20.0
    /// A withering cell fades out over this long.
    static let witherFade = 0.9
    /// A shoot starts every 30 to 60 s.
    static let shootEvery = 45.0
    /// Shoots growing at once.
    static let maxShoots = 3
    /// Longest span simulated after a pause; beyond it the garden is statistically the same.
    static let catchUp = 1200.0

    struct Born {
        let cell: VineCell
        let at: Double
    }

    struct Withered {
        let cell: VineCell
        /// When this cell starts to fade; cells nearer the tip start first.
        let at: Double
        /// Which branch's withering it belongs to.
        let event: Int
    }

    /// A bloom's petal tumbling down; `position` and `alpha` are pure in its age.
    struct Petal {
        let x: Double
        let y: Double
        let vx: Double
        let vy: Double
        let life: Double
        let phase: Double
        let colour: Int
        let at: Double

        static let glyphs: [Character] = ["'", "`", ",", "˙"]
        /// How long a petal shows each glyph as it tumbles.
        static let tumble = 0.34

        func position(age: Double) -> CGPoint {
            CGPoint(x: x + vx * age + sin(age * 1.7 + phase) * 9, y: y + vy * age)
        }

        func alpha(age: Double) -> Double {
            0.85 * Self.smooth(0, 0.5, age) * (1 - Self.smooth(life - 1.5, life, age))
        }

        func glyph(age: Double) -> Character {
            Self.glyphs[Int((age / Self.tumble + phase).rounded(.down)) & 3]
        }

        private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(1, max(0, (x - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
    }

    /// Spores a cell lets go of: a new bloom opening, or a leaf or bloom withering away.
    struct Spores {
        let cell: VineCell
        let at: Double
    }

    struct Changes {
        var born: [Born] = []
        var withered: [Withered] = []
        var petals: [Petal] = []
        var spores: [Spores] = []
        var isEmpty: Bool { born.isEmpty && withered.isEmpty && petals.isEmpty && spores.isEmpty }
    }

    private(set) var field: VineField
    /// Simulated seconds since the garden began to live.
    private(set) var time = 0.0
    /// Cells the garden keeps: the density it had when it finished growing.
    let cap: Int
    private let roots: Int
    private var random: VineRandom
    private var ticks = 0
    private var witherEvents = 0
    private var nextShoot: Double
    private var nextCompost: Double
    private var nextPetal: Double
    /// Seconds between petals for this garden.
    let petalEvery: Double

    init(field grown: VineField, roots: Int, seed: UInt32, petalEvery: Double = 9) {
        var field = grown
        // Growth ends by each shoot's own life now, not by the garden's budget.
        field.budget = .max
        field.maxCells = max(field.maxCells, field.cells.count * 3 / 2 + 64)
        field.logsPlacements = true
        self.field = field
        cap = field.cells.count
        self.roots = roots
        self.petalEvery = petalEvery
        random = VineRandom(seed: seed ^ 0x51ED_270B)
        nextShoot = 6
        nextCompost = 10
        nextPetal = 4 + random.next() * petalEvery * 0.5
    }

    /// Runs the garden forward to `target`, returning everything that started on the way.
    /// A gap longer than `catchUp` skips its oldest part: the garden is as dense as ever.
    mutating func advance(to target: Double) -> Changes {
        var changes = Changes()
        if target - time > Self.catchUp { skip(to: target - Self.catchUp) }
        while Double(ticks + 1) * Self.tick <= target {
            ticks += 1
            step(at: Double(ticks) * Self.tick, into: &changes)
        }
        time = max(time, target)
        return changes
    }

    /// Jumps the clock without growing anything, keeping the schedule where it was relative to now.
    private mutating func skip(to moment: Double) {
        let jump = moment - Double(ticks) * Self.tick
        guard jump > 0 else { return }
        ticks = Int(moment / Self.tick)
        nextShoot += jump; nextCompost += jump; nextPetal += jump
        time = moment
    }

    // MARK: One growth step

    private mutating func step(at t: Double, into changes: inout Changes) {
        if t >= nextShoot {
            nextShoot = t + Self.shootEvery * (0.67 + random.next() * 0.66)
            if field.tipCount < Self.maxShoots { spawnShoot() }
        }
        if field.tipCount > 0 { field.step() }
        for cell in field.takePlaced() {
            changes.born.append(Born(cell: cell, at: t))
            if cell.kind == .bloom { changes.spores.append(Spores(cell: cell, at: t)) }
        }
        if t >= nextCompost {
            if field.cells.count > cap, let withered = wither(at: t) {
                changes.withered += withered
                for item in withered where item.cell.kind != .stem && Noise.unit(item.cell.phase * 7 + 1) < 0.5 {
                    changes.spores.append(Spores(cell: item.cell, at: item.at))
                }
                nextCompost = t + 24
            } else {
                // Back off whether or not a branch was ready, so the search never runs every step.
                nextCompost = t + Self.tick
            }
        }
        if t >= nextPetal {
            nextPetal = t + petalEvery * (0.6 + random.next() * 0.8)
            if let petal = shedPetal(at: t) { changes.petals.append(petal) }
        }
    }

    // MARK: Shoots

    private mutating func spawnShoot() {
        let columns = field.columns
        let stems = field.cells.values.filter { cell in
            cell.kind == .stem && cell.y > 3 && (field.branches[cell.branch]?.generation ?? 0) < 2
        }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        if roots > 0 && (stems.isEmpty || random.next() < 0.3) {
            // A new vine rising from the bottom edge, where the garden's roots are.
            for _ in 0..<8 {
                let x = Int(random.next() * Double(columns))
                guard field.allows(x, field.rows - 1) else { continue }
                var spec = VineTipSpec(x: x, y: field.rows - 1, heading: -.pi / 2 + (random.next() - 0.5) * 0.6,
                                       life: 30 + Int(random.next() * 26), bias: -.pi / 2, biasStrength: 0.035,
                                       hue: Int(random.next() * 8), branchChance: 0.085, branchLife: 18)
                spec.living = true
                field.plant(spec)
                return
            }
        }
        guard !stems.isEmpty else { return }
        let cell = stems[Int(random.next() * Double(stems.count))]
        let side: Double = random.next() < 0.5 ? -1 : 1
        var spec = VineTipSpec(x: cell.x, y: cell.y, heading: -.pi / 2 + side * (0.55 + random.next() * 0.6),
                               life: 10 + Int(random.next() * 14), generation: (field.branches[cell.branch]?.generation ?? 0) + 1,
                               bias: -.pi / 2 + side * 0.4, biasStrength: 0.03, curl: (random.next() - 0.5) * 0.08,
                               hue: Int(random.next() * 4), branchChance: 0.05, leafChance: 0.32, maxGeneration: 3, branchLife: 9)
        spec.parent = cell.branch
        spec.living = true
        field.plant(spec)
    }

    // MARK: Withering

    /// Starts the oldest settled branch, and everything that grew from it, withering from its
    /// tip back to its stem. Prefers a branch small enough not to thin the garden at once.
    private mutating func wither(at t: Double) -> [Withered]? {
        let active = field.activeBranches
        var byBranch: [Int: [VineCell]] = [:]
        for cell in field.cells.values { byBranch[cell.branch, default: []].append(cell) }
        var kids: [Int: [Int]] = [:]
        for (id, branch) in field.branches { if let parent = branch.parent { kids[parent, default: []].append(id) } }
        let limit = max(40, cap / 10)
        var best: (size: Int, doomed: Set<Int>)?
        for id in field.branches.keys.sorted() {
            guard let branch = field.branches[id], !branch.gone, branch.generation >= 1 || branch.living,
                  !active.contains(id), (byBranch[id]?.count ?? 0) >= 5 else { continue }
            var doomed = Set<Int>(), stack = [id], busy = false
            while let next = stack.popLast() {
                if doomed.contains(next) { continue }
                if active.contains(next) { busy = true; break }
                doomed.insert(next)
                stack += kids[next] ?? []
            }
            if busy { continue }
            let size = doomed.reduce(0) { $0 + (byBranch[$1]?.count ?? 0) }
            if size <= limit { best = (size, doomed); break }
            if best == nil || size < best!.size { best = (size, doomed) }
        }
        guard let chosen = best else { return nil }
        let cells = chosen.doomed.flatMap { byBranch[$0] ?? [] }.sorted { $0.seq > $1.seq }
        field.markGone(Array(chosen.doomed))
        field.remove(cells.map { VineField.key($0.x, $0.y, columns: field.columns) })
        witherEvents += 1
        let event = witherEvents
        return cells.enumerated().map { index, cell in
            Withered(cell: cell, at: t + Double(index) / Double(max(1, cells.count)) * Self.witherSpan, event: event)
        }
    }

    // MARK: Petals

    private mutating func shedPetal(at t: Double) -> Petal? {
        let blooms = field.cells.values.filter { $0.kind == .bloom }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        guard !blooms.isEmpty else { return nil }
        let bloom = blooms[Int(random.next() * Double(blooms.count))]
        return Petal(x: (Double(bloom.x) + 0.5) * field.cellWidth, y: (Double(bloom.y) + 0.6) * field.cellHeight,
                     vx: 6 + random.next() * 8, vy: 14 + random.next() * 12, life: 6.5 + random.next() * 3,
                     phase: random.next() * 2 * .pi, colour: bloom.slot % 4, at: t)
    }
}

// MARK: - Wind

/// Slow bands of wind crossing the garden. A band is a soft bump that travels left to right and
/// rests off-screen between crossings; leaves flutter wherever it is.
struct GardenWind: Equatable {
    let width: Double
    let bandWidth: Double
    /// Seconds for a band to cross, and between the starts of two crossings.
    let crossing: Double
    let period: Double

    static let speed = 110.0

    init(width: Double) {
        self.width = width
        bandWidth = max(150, width * 0.28)
        crossing = (width + bandWidth) / Self.speed
        period = max(10, crossing + 2)
    }

    /// The band's centre `t` seconds into a period.
    func centre(at t: Double) -> Double {
        let u = t.truncatingRemainder(dividingBy: period)
        let start = -bandWidth / 2, end = width + bandWidth / 2
        return u >= crossing ? end : start + (end - start) * u / crossing
    }

    /// How windy it is at `x` when the band is at `centre`: 1 inside it, 0 outside, soft between.
    func strength(at x: Double, centre: Double) -> Double {
        let q = min(1, abs(x - centre) / (bandWidth / 2))
        return 1 - q * q * (3 - 2 * q)
    }
}

// MARK: - Fireflies

/// One firefly (a pollen mote in light mode): a slow wander through free space, played back and
/// forth by the render server, blinking on its own 3 to 6 s cycle.
struct FireflyTrack {
    /// Seconds between samples of the path.
    static let sampleEvery = 0.5
    static let samples = 181

    let points: [CGPoint]
    /// Radians per second of the blink, and where in the cycle it starts.
    let omega: Double
    let phase: Double
    let dark: Bool

    var duration: Double { Double(points.count - 1) * Self.sampleEvery }

    func position(at t: Double) -> CGPoint {
        let span = duration, cycle = t.truncatingRemainder(dividingBy: 2 * span)
        let u = (cycle <= span ? cycle : 2 * span - cycle) / Self.sampleEvery
        let i = min(points.count - 2, Int(u)), f = u - Double(i)
        return CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * f, y: points[i].y + (points[i + 1].y - points[i].y) * f)
    }

    /// Opacity of the blink: a sharp glow after dark, a gentle shimmer by day.
    func blink(at t: Double) -> Double {
        let s = sin(t * omega + phase)
        if dark {
            let x = min(1, max(0, (s - 0.45) / 0.55))
            return 0.12 + 0.88 * x * x * (3 - 2 * x)
        }
        return 0.45 + 0.4 * s
    }

    /// Walks a firefly through the places `isFree` allows. Returns nil when it cannot start anywhere.
    static func make(index: Int, seed: UInt32, size: CGSize, dark: Bool, isFree: (CGPoint) -> Bool) -> FireflyTrack? {
        var random = VineRandom(seed: seed &* 2_654_435_761 &+ UInt32(index) &* 40_503 &+ 11)
        var start: CGPoint?
        for _ in 0..<300 {
            let point = CGPoint(x: random.next() * size.width, y: random.next() * size.height)
            if isFree(point) { start = point; break }
        }
        guard var position = start else { return nil }
        let wander = random.next() * 50, speed = dark ? 15.0 : 10.0
        var points = [position]
        for step in 1..<samples {
            let t = Double(step) * sampleEvery
            var angle = Noise.value(position.x * 0.006 + wander, position.y * 0.006 + t * 0.12) * 4 * .pi
            var next = position
            // Turn aside from anything occupied, and from the garden's edge.
            for _ in 0..<12 {
                next = CGPoint(x: position.x + cos(angle) * speed * sampleEvery,
                               y: position.y + (sin(angle) * speed - (dark ? 0 : 3)) * sampleEvery)
                if isFree(next) { break }
                angle += 0.55
                next = position
            }
            position = next
            points.append(position)
        }
        return FireflyTrack(points: points, omega: 0.9 + random.next() * 1.1, phase: random.next() * 2 * .pi, dark: dark)
    }
}

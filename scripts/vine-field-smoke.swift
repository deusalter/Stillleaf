import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(("vine-field-smoke FAILED: " + message + "\n").data(using: .utf8)!)
        exit(1)
    }
}

func garden(seed: UInt32, columns: Int = 120, rows: Int = 44, budget: Int = .max,
            allows: @escaping (Int, Int) -> Bool = { _, _ in true }) -> VineField {
    var field = VineField(columns: columns, rows: rows, cellWidth: 7.8, cellHeight: 16, seed: seed, maxCells: 2400)
    field.budget = budget
    field.allows = allows
    for i in 0..<9 {
        field.plant(VineTipSpec(x: 6 + i * columns / 10, y: rows - 1, heading: -.pi / 2, life: 46, bias: -.pi / 2,
                                biasStrength: 0.035, hue: i, branchChance: 0.085, branchLife: 18))
    }
    field.growToCompletion(limit: 20_000)
    return field
}

func signature(_ field: VineField) -> [Int: String] {
    field.cells.mapValues { "\($0.glyph)\($0.kind.rawValue)" }
}

@main struct VineFieldSmoke {
    static func main() {
        // Determinism: the same seed grows the same garden; another seed grows another.
        let a = garden(seed: 42), b = garden(seed: 42), c = garden(seed: 43)
        check(a.cells.count > 200, "garden grew only \(a.cells.count) cells")
        check(signature(a) == signature(b), "the same seed grew different gardens")
        check(Set(a.cells.keys) != Set(c.cells.keys), "different seeds grew the same garden")
        check(a.cells.values.contains { $0.kind == .leaf } && a.cells.values.contains { $0.kind == .bloom }, "no leaves or blooms")

        // Masks: no cell inside a refused rectangle.
        let refused = { (x: Int, y: Int) in x >= 40 && x < 80 && y >= 10 && y < 30 }
        let masked = garden(seed: 7, allows: { !refused($0, $1) })
        check(masked.cells.values.allSatisfy { !refused($0.x, $0.y) }, "a cell landed in a refused region")

        // The header clearing holds at the minimum dashboard size.
        let small = garden(seed: 9, columns: 90, rows: 38, allows: { _, y in y >= 7 })
        check(!small.cells.isEmpty && small.cells.values.allSatisfy { $0.y >= 7 }, "a vine entered the header clearing")

        // Budgets: growth under a larger budget starts with the smaller budget's cells.
        let short = garden(seed: 5, budget: 300), long = garden(seed: 5, budget: 900)
        check(short.cells.count >= 300 && short.cells.count <= 304, "budget not respected: \(short.cells.count)")
        check(Set(short.cells.keys).isSubset(of: Set(long.cells.keys)), "a larger budget does not start with the smaller one")

        // One-cell stepping: consecutive stem cells of one tip always touch.
        var line = VineField(columns: 60, rows: 30, cellWidth: 7.8, cellHeight: 16, seed: 3, maxCells: 400)
        line.plant(VineTipSpec(x: 2, y: 15, heading: 0, life: 40, branchChance: 0, leafChance: 0, bloomChance: 0))
        line.growToCompletion(limit: 200)
        let stems = line.cells.values.filter { $0.kind == .stem }.sorted { $0.step < $1.step }
        check(stems.count > 20, "the single tip grew only \(stems.count) stems")
        for (p, q) in zip(stems, stems.dropFirst()) {
            check(abs(p.x - q.x) <= 1 && abs(p.y - q.y) <= 1, "gap between \(p.x),\(p.y) and \(q.x),\(q.y)")
        }

        // Path followers stay on their path when they do not wobble.
        var ring = VineField(columns: 40, rows: 20, cellWidth: 7.2, cellHeight: 15, seed: 4, maxCells: 400)
        let path = (0...120).map { i -> VinePoint in
            let angle = Double(i) / 120 * .pi
            return VinePoint(x: 20 + cos(angle) * 15, y: 10 + sin(angle) * 7)
        }
        ring.plant(VineTipSpec(x: 35, y: 10, life: 9999, leafChance: 0, bloomChance: 0, path: path, wobble: 0))
        ring.growToCompletion(limit: 500)
        check(ring.cells.count > 20, "the path follower grew only \(ring.cells.count) cells")
        check(ring.cells.values.allSatisfy { cell in path.contains { abs($0.x - Double(cell.x)) <= 1 && abs($0.y - Double(cell.y)) <= 1 } },
              "the path follower left its path")

        // Resizing regrows within the new bounds.
        let resized = garden(seed: 42, columns: 70, rows: 30)
        check(resized.cells.values.allSatisfy { $0.x >= 0 && $0.x < 70 && $0.y >= 0 && $0.y < 30 }, "a cell fell outside the resized grid")

        // Heads report live tips while growing and none once grown.
        var growing = VineField(columns: 60, rows: 30, cellWidth: 7.8, cellHeight: 16, seed: 8, maxCells: 400)
        growing.plant(VineTipSpec(x: 30, y: 29, branchChance: 0))
        growing.step()
        check(growing.isGrowing && growing.heads.count == 1, "a growing tip has no head")
        growing.growToCompletion(limit: 1000)
        check(!growing.isGrowing && growing.heads.isEmpty, "a finished garden still reports heads")

        // Daily seeds: stable within a day, different across days and kinds.
        check(GardenSeed.daily("dashboard", day: "2026-10-04") == GardenSeed.daily("dashboard", day: "2026-10-04"), "daily seed is unstable")
        check(GardenSeed.daily("dashboard", day: "2026-10-04") != GardenSeed.daily("dashboard", day: "2026-10-05"), "daily seed ignores the day")
        check(GardenSeed.daily("dashboard", day: "2026-10-04") != GardenSeed.daily("popover", day: "2026-10-04"), "daily seed ignores the kind")

        print("vine-field-smoke: determinism, masks, clearing, budget prefix, gap-free stems, path followers, resize bounds, heads, daily seeds passed")
    }
}

# Glass + ASCII Vines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the approved glass + ASCII vines redesign: a Garden dashboard, a margin-garden reader, and vines in empty states, onboarding and completion. Each of the four phases is a pull request.

**Architecture:** A pure, deterministic vine model (`VineField`) feeds a SwiftUI `Canvas` renderer (`GardenCanvas`) placed behind glass surfaces (`GlassSurface`). The reader gets a JavaScript port of the same model (`vines.js`). Its geometry layer (`garden.js`) reads the reader’s own layout, so vines only grow in empty margins and the column gap. Theme colours feed a palette function (`VinePalette`) in both languages.

**Tech stack:** Swift 5.8 floor (Command Line Tools build via `scripts/build-local.sh`), SwiftUI/AppKit on macOS 13+, glass APIs behind `#if compiler(>=6.2)` + `#available(macOS 26.0, *)`. Reader: ES modules bundled by Vite, tests with `node:test` + Playwright (Chrome and WebKit).

**Spec:** `docs/specs/glass-vines.md` (read it first; this plan argues from it). Mockups in `design/glass-vines/` are the visual reference; their inline script is the reference algorithm.

## Global constraints

- macOS 13 deployment target. Swift 5.8 must compile (`scripts/build-local.sh`). Newer APIs need `#if compiler(>=5.9)` (macOS 14) or `#if compiler(>=6.2)` (macOS 26) plus `#available`.
- No new package dependencies, in Swift or JavaScript.
- **Never behind bare text:** ASCII is only allowed behind glass or in avoid-free space, never directly behind text drawn on the canvas.
- Garden setting values are exactly `animated`, `still`, `off` (UserDefaults key `gardenMode`, default `animated`). Reduce Motion or Low Power Mode → effective `still`.
- Reader preference `vines`: exactly `margins` or `off` (default `margins`).
- Frame pacing: growth at most 60 fps, breathing 20 fps, nothing when the window is hidden, occluded, minimised, `still` or `off`.
- Budgets: dashboard garden ≤ 2,400 cells; reader margins ≤ 1,500 cells.
- Minimum reader margin for a garden: 7 cells.
- Progress readouts on the dashboard stay dotted (the existing ring; new dotted rows). Vines never represent dashboard data.
- Decorative layers: `accessibilityHidden(true)` (Swift) and `aria-hidden="true"` + `pointer-events: none` (reader).
- Commits use the user’s identity with no AI attribution trailers. Branches are `<area>/<topic>`.
- Every phase ends with `scripts/check-local.sh` passing, the reader test suite passing (Phase 3), and before/after renders reviewed.

## Review focus

The failure modes most likely to bite a real user that no feature test naturally exercises. Each has a pinned test in the task named.

1. **Resizing the dashboard window during or after growth** must regrid without stray cells outside the grid or a crash. Expected: the garden regrows for the new size. Test: Task 1, `resizeRegrowsWithinBounds`.
2. **Switching theme or light/dark mid-growth** must recolour live without restarting growth. Test: Task 2, the palette is derived from a snapshot, and Task 4 renders a theme switch at a frozen time.
3. **The minimum window size (920×660)** must keep the header clearing intact. Expected: no vine cell inside the clearing at any size. Test: Task 1, `clearingHoldsAtMinimumSize`.
4. **Reader with no usable margins** (narrow window, page width 100%) must produce no garden and no errors. Expected: the reader looks exactly as today. Test: Task 9, `garden.test.mjs` “no margins, no garden”.
5. **Garden set to Off** must start no timers. Expected: zero frames rendered after the first. Test: Task 4, `GardenClock` reports no ticks when off.

---

## Phase 1: Engine, palette, glass and the Today screen (PR `ui/glass-vines`)

### Task 1: `VineField`, a pure deterministic vine model

**Files:**
- Create: `Sources/BooksPresence/Vines/VineField.swift`
- Create: `scripts/vine-field-smoke.swift`
- Modify: `scripts/check-local.sh` (compile and run the smoke)
- Modify: `scripts/build-local.sh` (add `Sources/BooksPresence/Vines/*.swift`)

**Interfaces:**
- Produces:
  - `struct VinePoint { var x: Double; var y: Double }`
  - `enum VineKind: Int { case stem = 1, leaf, bloom }`
  - `struct VineCell { x, y: Int; glyph: Character; alternate: Character?; kind: VineKind; slot: Int; step: Int; phase: Double }`
  - `struct VineTipSpec`: the fields `x`, `y`, `heading`, `life`, `generation`, `bias`, `biasStrength`, `curl`, `hue`, `branchChance`, `leafChance`, `bloomChance`, `maxGeneration`, `branchLife`, `path`, `wobble`, `wobbleFrequency`
  - `struct VineField` with:
    - `init(columns:rows:cellWidth:cellHeight:seed:maxCells:)`
    - `var budget: Int`
    - `var allows: (Int, Int) -> Bool`
    - `private(set) var cells: [Int: VineCell]`
    - `private(set) var stepCount: Int`
    - `var isGrowing: Bool`
    - `mutating func plant(_:)`
    - `mutating func step()`
    - `mutating func growToCompletion(limit:)`
    - `var heads: [VinePoint]`
  - `static func key(_ x: Int, _ y: Int, columns: Int) -> Int`
  - `enum VineGlyphs` with `stem(dx:dy:)`, `leaves`, `flutter`, `blooms`, `pollen`

- [ ] **Step 1: Write the failing smoke.** `scripts/vine-field-smoke.swift`:

```swift
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { FileHandle.standardError.write(("vine-field-smoke FAILED: " + message + "\n").data(using: .utf8)!); exit(1) }
}

func garden(seed: UInt32, columns: Int = 120, rows: Int = 44, budget: Int = .max, allows: @escaping (Int, Int) -> Bool = { _, _ in true }) -> VineField {
    var field = VineField(columns: columns, rows: rows, cellWidth: 7.8, cellHeight: 16, seed: seed, maxCells: 2400)
    field.budget = budget
    field.allows = allows
    for i in 0..<9 { field.plant(VineTipSpec(x: 6 + i * 12, y: rows - 1, heading: -.pi / 2, life: 46, bias: -.pi / 2, biasStrength: 0.035, hue: i, branchChance: 0.085, branchLife: 18)) }
    field.growToCompletion(limit: 20_000)
    return field
}

@main struct VineFieldSmoke {
    static func main() {
        // Determinism: the same seed grows the same garden.
        let a = garden(seed: 42), b = garden(seed: 42), c = garden(seed: 43)
        check(a.cells.count > 200, "garden grew \(a.cells.count) cells")
        check(a.cells.mapValues { "\($0.glyph)\($0.kind.rawValue)" } == b.cells.mapValues { "\($0.glyph)\($0.kind.rawValue)" }, "same seed differs")
        check(Set(a.cells.keys) != Set(c.cells.keys), "different seeds match")

        // Masks: no cell inside a refused rectangle.
        let refused = { (x: Int, y: Int) in x >= 40 && x < 80 && y >= 10 && y < 30 }
        let masked = garden(seed: 7, allows: { !refused($0, $1) })
        check(masked.cells.values.allSatisfy { !refused($0.x, $0.y) }, "cell placed in refused region")

        // Clearing holds at the minimum dashboard size (Review focus 3).
        let clearing = { (_: Int, y: Int) in y >= 7 }
        let small = garden(seed: 9, columns: 90, rows: 38, allows: clearing)
        check(small.cells.values.allSatisfy { $0.y >= 7 }, "vine entered the header clearing")

        // Budgets: a larger budget starts with the smaller budget's cells.
        let short = garden(seed: 5, budget: 300), long = garden(seed: 5, budget: 900)
        check(Set(short.cells.keys).isSubset(of: Set(long.cells.keys)), "budget growth is not a prefix")
        check(short.cells.count <= 302, "budget exceeded: \(short.cells.count)")

        // One-cell stepping: every stem cell of a single tip touches the previous one.
        var line = VineField(columns: 60, rows: 30, cellWidth: 7.8, cellHeight: 16, seed: 3, maxCells: 400)
        line.plant(VineTipSpec(x: 2, y: 15, heading: 0, life: 40, branchChance: 0, leafChance: 0, bloomChance: 0))
        line.growToCompletion(limit: 200)
        let stems = line.cells.values.filter { $0.kind == .stem }.sorted { $0.step < $1.step }
        for (p, q) in zip(stems, stems.dropFirst()) { check(abs(p.x - q.x) <= 1 && abs(p.y - q.y) <= 1, "gap between \(p.x),\(p.y) and \(q.x),\(q.y)") }

        // Path followers stay on their path within the wobble.
        var ring = VineField(columns: 40, rows: 20, cellWidth: 7.2, cellHeight: 15, seed: 4, maxCells: 400)
        let path = (0...60).map { i -> VinePoint in let a = Double(i) / 60 * .pi; return VinePoint(x: 20 + cos(a) * 15, y: 10 + sin(a) * 7) }
        ring.plant(VineTipSpec(x: 35, y: 10, life: 9999, leafChance: 0, bloomChance: 0, path: path, wobble: 0))
        ring.growToCompletion(limit: 500)
        check(ring.cells.values.allSatisfy { c in path.contains { abs($0.x - Double(c.x)) <= 1 && abs($0.y - Double(c.y)) <= 1 } }, "path follower left its path")

        // Resizing regrows within the new bounds (Review focus 1).
        let resized = garden(seed: 42, columns: 70, rows: 30)
        check(resized.cells.values.allSatisfy { $0.x >= 0 && $0.x < 70 && $0.y >= 0 && $0.y < 30 }, "cell outside resized grid")
        print("vine-field-smoke: determinism, masks, clearing, budget prefix, gap-free stems, path followers, resize bounds passed")
    }
}
```

- [ ] **Step 2: Wire it into `check-local.sh` and run it (expect a compile failure: `VineField` undefined).**

In `scripts/check-local.sh`, after the `native-date-field-smoke` lines, add:

```bash
"$SWIFTC" -parse-as-library -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx13.0" Sources/BooksPresence/Vines/VineField.swift scripts/vine-field-smoke.swift -o "$OUT/vine-field-smoke"
"$OUT/vine-field-smoke"
```

Run: `swiftc -parse-as-library Sources/BooksPresence/Vines/VineField.swift scripts/vine-field-smoke.swift -o /tmp/vfs`
Expected: error, no such file.

- [ ] **Step 3: Implement `VineField.swift`.** Port the mockup algorithm (`design/glass-vines/directions.html`, class `Scene`) without rendering:
  - **Random numbers:** xorshift32 (`s ^= s << 13; s ^= s >> 17; s ^= s << 5`, value `/ 2^32`), seeded with `seed * 9973 + 17`, the same as the JS.
  - **Wandering tip:** `drift = drift * 0.82 + (r − 0.5) * 0.42`, heading `+= drift + bias correction × biasStrength + curl`. Step length is `0.999 / max(|cos|/cellWidth, |sin|/cellHeight)` points. If a refused cell is hit, turn by ±(0.7 + r·0.6) and retry up to 3 times, then the tip dies. Glyph comes from `VineGlyphs.stem(dx:dy:)` using point deltas (22.5°/67.5°/112.5°/157.5° buckets → `─ ╲ │ ╱`). At generation ≥ 2, a sharp turn gives `)` or `(`, and horizontal gives `~`.
  - **Path follower:** advance along `path` points; offset by `wobble · sin(i · wobbleFrequency + phase)` along the normal, with the y component × 0.6; place a cell when the rounded cell changes.
  - **Sprouting:**
    - leaf with chance `leafChance` (× 0.7 at generation > 1): a perpendicular neighbour, using a side pair from `VineGlyphs.leaves`
    - branch with chance `branchChance` while `generation < maxGeneration` and `tips < maxTips`: life `branchLife · (0.4 + r · 0.8)`
    - when a tip dies, a bloom with chance `bloomChance`, one cell ahead
  - **Placement rules:** refuse out-of-bounds, `!allows`, `cells.count >= maxCells`, or an existing cell of equal or higher kind rank. Record `step = stepCount`.
  - `step()` returns immediately when `cells.count >= budget`. Otherwise it advances each tip once (newest first, removing dead tips) and increments `stepCount`.
  - `heads` returns each live tip’s position in points.

```swift
import Foundation

struct VinePoint: Equatable { var x: Double; var y: Double }
enum VineKind: Int { case stem = 1, leaf, bloom }

struct VineCell: Equatable {
    let x: Int, y: Int
    let glyph: Character
    let alternate: Character?
    let kind: VineKind
    let slot: Int
    let step: Int
    let phase: Double
}

enum VineGlyphs {
    static let leaves: [(Character, Character)] = [("(", ")"), ("{", "}"), ("6", "9"), ("@", "@"), ("o", "o"), ("(", ")")]
    static let flutter: [Character: Character] = ["(": "{", ")": "}", "{": "(", "}": ")", "6": "(", "9": ")", "@": "o", "o": "@"]
    static let blooms: [Character] = ["✿", "❀", "✽", "*", "❁", "✻"]
    static let pollen: [Character] = [".", "·", ":", "˙", "'", "`", ",", "·"]
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
    var path: [VinePoint]? = nil
    var wobble = 0.0
    var wobbleFrequency = 0.33
}
```

Fill in `struct VineField` per the bullets above. `growToCompletion(limit:)` calls `step()` while `isGrowing` and under `limit`.

- [ ] **Step 4: Run the smoke and confirm it passes.**

Run: `swiftc -parse-as-library Sources/BooksPresence/Vines/VineField.swift scripts/vine-field-smoke.swift -o /tmp/vfs && /tmp/vfs`
Expected: `vine-field-smoke: … passed`

- [ ] **Step 5: Add `Sources/BooksPresence/Vines/*.swift` to the app glob in `scripts/build-local.sh`, build with `BOOKSPRESENCE_SKIP_READER_BUILD=1`, then commit.**

```bash
git add Sources/BooksPresence/Vines/VineField.swift scripts/vine-field-smoke.swift scripts/check-local.sh scripts/build-local.sh
git commit -m "Add a deterministic vine growth model"
```

### Task 2: `VinePalette`, vine colours from any theme

**Files:**
- Create: `Sources/BooksPresence/Vines/VinePalette.swift` (Foundation only; uses `ThemeColors` from `Theme.swift`)
- Modify: `scripts/theme-contrast-smoke.swift` (vine checks)
- Modify: `scripts/check-local.sh` (the theme-contrast compile line also takes `VinePalette.swift`)

**Interfaces:**
- Consumes: `ThemeColors`, `ThemeContrast` (Theme.swift)
- Produces:
  - `struct VinePalette { stems: [UInt32]; leaves: [UInt32]; blooms: [UInt32]; head: UInt32; pollen: UInt32; pollenAlpha: Double; track: UInt32; baseAlpha: Double; static func make(_ colors: ThemeColors, dark: Bool) -> VinePalette }`
  - `func color(_ kind: VineKind, slot: Int) -> UInt32`

- [ ] **Step 1: Write the failing check** in `theme-contrast-smoke.swift`. For every theme in `ReadingTheme.all`, both appearances, and every colour in `stems + leaves + blooms`:

```swift
for theme in ReadingTheme.all {
    for dark in [false, true] {
        let colors = theme.colors(dark: dark, accent: nil)
        let palette = VinePalette.make(colors, dark: dark)
        for hex in palette.stems + palette.leaves + palette.blooms {
            let ratio = ThemeContrast.ratio(hex, colors.canvas)
            guard ratio >= 3 else { fail("\(theme.id) \(dark ? "dark" : "light") vine \(String(hex, radix: 16)) is \(ratio):1 on canvas") }
        }
    }
}
```

(Use the smoke’s existing failure helper and `ThemeContrast` function names. Read the file first and match them exactly.)

- [ ] **Step 2: Run it and confirm it fails** (`VinePalette` undefined).
- [ ] **Step 3: Implement `make`.**
  - HSL helpers; hue `h` and saturation `s` are clamped to 0.38…0.8.
  - leaves: hue offsets `[0, 16, −14, 30, −28]`, lightness `[0.64, 0.71, 0.57, 0.75, 0.67]` (dark) or `[0.36, 0.42, 0.32, 0.29, 0.40]` (light)
  - stems: `[accent, mix(accent, ink, 0.25), mix(accent, chart[2], 0.35), hsl(h, s·0.9, dark ? 0.46 : 0.26)]`
  - blooms: `[chart[1], dark ? 0xF5C65E : 0xD48E14, hsl(h + 150, 0.62, dark ? 0.72 : 0.52), hsl(h + 205, 0.55, dark ? 0.74 : 0.50)]`
  - `pollenAlpha`: 0.19 dark / 0.24 light. `baseAlpha`: 0.85 / 0.96.
  - If a colour fails 3:1, step its lightness toward contrast in 0.03 increments, at most 8 times. That keeps the formula and guarantees the check.
- [ ] **Step 4: Run `scripts/check-local.sh` up to the theme smoke** and confirm it passes for all 12 variants.
- [ ] **Step 5: Commit** with the message `Derive vine colours from each theme`.

### Task 3: The Garden setting

**Files:**
- Modify: `Sources/BooksPresence/ThemeStore.swift` (persisted `gardenMode`)
- Modify: `Sources/BooksPresence/AppearancePicker.swift` (Garden section)
- Modify: `Sources/BooksPresence/DevTools/UISmoke.swift` (persistence check)

**Interfaces:**
- Produces:
  - `enum GardenMode: String, CaseIterable, Identifiable { case animated, still, off }` with `label`
  - `ThemeStore.gardenMode: GardenMode` (published through `revision`)
  - `ThemeStore.select(garden:)`
  - `static let gardenKey = "gardenMode"`
  - `func effectiveGardenMode(reduceMotion: Bool) -> GardenMode`, which returns `.still` when `reduceMotion` or `ProcessInfo.processInfo.isLowPowerModeEnabled` and the mode is `.animated`

- [ ] **Step 1: Write the failing UI smoke** next to the existing “6 themes persisted” block:

```swift
let gardenDefaults = UserDefaults(suiteName: "stillleaf-garden-smoke-\(UUID().uuidString)")!
let gardenStore = ThemeStore(defaults: gardenDefaults)
guard gardenStore.gardenMode == .animated else { throw BooksAccessErrorForUI.failed("Garden did not default to animated") }
gardenStore.select(garden: .off)
guard ThemeStore(defaults: gardenDefaults).gardenMode == .off else { throw BooksAccessErrorForUI.failed("Garden mode did not persist") }
guard gardenStore.effectiveGardenMode(reduceMotion: true) == .off else { throw BooksAccessErrorForUI.failed("Reduce Motion changed an Off garden") }
gardenStore.select(garden: .animated)
guard gardenStore.effectiveGardenMode(reduceMotion: true) == .still else { throw BooksAccessErrorForUI.failed("Reduce Motion did not still the garden") }
```

- [ ] **Step 2: Build and run `--self-test-ui`.** Expect a compile failure.
- [ ] **Step 3: Implement it in `ThemeStore`.** Load it in `load()`; `select(garden:)` writes the default and calls `publish()`. Add a `ReadingSection("Garden")` to `AppearancePicker` with a `ReadingSegmentedControl` (options `GardenMode.allCases`, symbols `leaf`, `pause.circle`, `circle.slash`) and a caption: “Animated vines grow when a window opens, then breathe. Still shows them without motion. Reduce Motion and Low Power use Still.”
- [ ] **Step 4: Build and run `--self-test-ui`; confirm the new lines pass.**
- [ ] **Step 5: Commit** with the message `Add the Garden appearance setting`.

### Task 4: `GardenCanvas`, rendering, pacing and the pollen field

**Files:**
- Create: `Sources/BooksPresence/Vines/GardenCanvas.swift`
- Create: `Sources/BooksPresence/Vines/GardenClock.swift`
- Create: `Sources/BooksPresence/Vines/WindowVisibility.swift`
- Modify: `Sources/BooksPresence/DevTools/UIRender.swift` (`--vine-time`)
- Modify: `Sources/BooksPresence/DevTools/UISmoke.swift` (clock checks)

**Interfaces:**
- Consumes: `VineField`, `VinePalette`, `GardenMode`, `ThemeSnapshot`
- Produces:
  - `struct GardenLayout { var size: CGSize; var clearingHeight: CGFloat; var seed: UInt32; var roots: Int; var pollen: Bool; var avoid: [CGRect] }`
  - `struct GardenCanvas: View` with `init(layout: GardenLayout, mode: GardenMode)`, accessibility hidden
  - `final class GardenClock`, a pure helper: `init(mode:)`, `func frameInterval(growing: Bool) -> TimeInterval?` (`nil` means no ticks), `var frozenTime: TimeInterval?` from the `STILLLEAF_VINE_TIME` environment variable or `--vine-time`
  - `struct WindowVisibility: NSViewRepresentable` that reports `Bool` through a binding from `NSWindow.didChangeOcclusionStateNotification` and miniaturise notifications

- [ ] **Step 1: Write the failing smoke** in `UISmoke.swift`:

```swift
guard GardenClock(mode: .off).frameInterval(growing: true) == nil else { throw BooksAccessErrorForUI.failed("An Off garden scheduled frames") }
guard GardenClock(mode: .still).frameInterval(growing: false) == nil else { throw BooksAccessErrorForUI.failed("A still garden scheduled frames") }
guard GardenClock(mode: .animated).frameInterval(growing: true) == 1.0 / 60 else { throw BooksAccessErrorForUI.failed("Growth is not paced at 60 fps") }
guard GardenClock(mode: .animated).frameInterval(growing: false) == 1.0 / 20 else { throw BooksAccessErrorForUI.failed("Breathing is not paced at 20 fps") }
```

- [ ] **Step 2: Build; expect failure.**
- [ ] **Step 3: Implement `GardenClock`.** `off` and `still` → `nil`. Animated → 1/60 while growing, else 1/20.
- [ ] **Step 4: Implement `GardenCanvas`.**
  - Measure an SF Mono 13 pt `M` with `NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)` for `cellWidth`; `cellHeight = round(13 × 1.22)`.
  - Build a `VineField` sized to the layout. `allows` refuses `y·cellHeight < clearingHeight` and any `avoid` rect inset by −1 cell.
  - Plant `roots` bottom tips spread evenly (heading −π/2 ± 0.3, bias −π/2, strength 0.035, life 30…56, branch 0.085, branchLife 18) plus one each from the top-right and left edges, as in the mockup.
  - Hold the field in a `@StateObject` model (`GardenModel: ObservableObject`) keyed by `layout`. Rebuild on size changes over 8 pt.
  - When the clock interval is non-nil, render with `TimelineView(.periodic(from: .now, by: interval))`; otherwise render one static frame. With `.still`, call `growToCompletion()` up front. With `.off`, show `EmptyView()`.
  - In `Canvas`, cache resolved glyphs per `(glyph, colourHex)` in a dictionary reset when `ThemeSnapshot.current().revision` changes.
  - Per cell, alpha is `fade(0.7 s since its step’s time) × baseAlpha × breath`, where breath is `0.84 + 0.16·sin(0.9t + 0.35·phase + 0.11x − 0.17y)` (skipped when still). Leaves cross-fade to `alternate` when `sin(1.25t − 0.085x + 0.05y + 0.08·phase)` exceeds 0.88. Draw heads as `•` while growing.
  - Pollen field: every 2nd column and every row outside the clearing, a fixed glyph from `VineGlyphs.pollen` picked by a hash of `(x, y)`. Alpha is `pollenAlpha × smoothstep(0.42, 0.85, n)`, where `n` is two octaves of value noise drifting at the mockup’s speeds.
  - Pause (no `TimelineView`) when `WindowVisibility` reports hidden.
  - `frozenTime` makes every frame render at that time after `growToCompletion()`, for deterministic renders.
- [ ] **Step 5: Add `--vine-time <seconds>` to `UIRender`.** It sets `GardenClock.frozenTime` before rendering; the existing “today” previews pick it up in Task 5. Run `--self-test-ui`, confirm it passes, and commit with the message `Render the garden behind dashboard content`.

### Task 5: `GlassSurface`, `DottedProgressRow` and the Garden on Today

**Files:**
- Create: `Sources/BooksPresence/Vines/GlassSurface.swift`
- Create: `Sources/BooksPresence/DottedProgress.swift` (shares geometry with `ReadingProgress.swift`)
- Modify: `Sources/BooksPresence/ReadingLayout.swift` (`readingPanel()` uses `GlassSurface`; `ReadingSection` gains `glass: Bool` and in Garden mode renders its title inside the glass card)
- Modify: `Sources/BooksPresence/DashboardView.swift` (detail background = canvas + `GardenCanvas`, with a header clearing from `PageHeader` height)
- Modify: `Sources/BooksPresence/TodayView.swift` (featured reading and manual sections on glass; a dotted book progress row under the title)
- Modify: `Sources/BooksPresence/HistoryAtlasStyle.swift` (`AtlasPanel` via `readingPanel()`, already done; verify glass)

**Interfaces:**
- Consumes: `ReadingMetrics.Radius.card`, `ReadingPalette`, `GardenCanvas`, `ThemeStore.gardenMode`
- Produces:
  - `extension View { func glassSurface(cornerRadius: CGFloat = ReadingMetrics.Radius.card) -> some View }`: macOS 26 `glassEffect(.regular.tint(surface 35%), in: .rect(cornerRadius:))`; macOS 13–25 `.background(.ultraThinMaterial)` + `surface.opacity(0.55)`; Reduce Transparency or Increased Contrast → opaque `surface`
  - `struct DottedProgressRow: View { init(fraction: Double, dots: Int = 36) }`: 8 pt dots, the track colour from the ring, the same smooth leading edge `min(1, max(0, f·count − i))`
  - `GardenLayout` creation in `DashboardView`

- [ ] **Step 1: Write the failing smoke.** In `UISmoke`, render `DottedProgressRow(fraction: 0.38)` offscreen at 360×12 with the existing `ImageRenderer`/`cacheDisplay` helper, and assert that the left third contains accent pixels and the right third does not. Also lay out `TodayView` with Garden on and off in both appearances (the existing layout loop), and assert no layout failure.
- [ ] **Step 2: Build; expect failure.**
- [ ] **Step 3: Implement.**
  - Under `DashboardView`’s detail `VStack`, add `.background { GardenCanvas(layout: …, mode: theme.effectiveGardenMode(reduceMotion: …)) }` inside the existing canvas background. The clearing height is the page header’s resting height (34 top + 30 title + 6 + 20 subtitle + 24 ≈ 114 pt). The seed is `GardenSeed.daily("dashboard", day: model.today.day)`: an FNV-1a hash of kind and day key, so the garden is stable all day and changes daily, per the spec’s determinism rule. Add `GardenSeed` to `VineField.swift`, with a smoke line checking that the same kind and day give the same seed and different days give different seeds.
  - `readingPanel()` switches to `glassSurface()`.
  - `ReadingSection(glass: true)` wraps title and content in one `readingPanel()`. Today passes `glass: true` for its featured reading and manual sections.
  - Featured reading shows `DottedProgressRow` when the book has a page fraction (`progress.page / totalPages` from `LibraryProgressLabel`’s observation, or `fraction`).
- [ ] **Step 4: Build, run `scripts/check-local.sh`, render** with `--render-ui .local/garden-after --offscreen --vine-time 6 --preview-filter today,today-empty,today-minutes,today-compact`, and look at the PNGs in light and dark. **Measure** idle CPU with the garden visible: `top -l 3 -pid $(pgrep -x BooksPresence)` after 10 s; the target is under 2%. If it’s over, swap resolved `Text` for pre-rendered glyph images in the cache (same keys).
- [ ] **Step 5: Commit, then open PR 1** (base `maintenance/code-structure`) with the before/after renders described.

---

## Phase 2: The rest of the dashboard, sheets and menu bar panel (PR `ui/glass-vines-dashboard`)

### Task 6: Garden behind every dashboard screen and the sidebar

**Files:**
- Modify: `Sources/BooksPresence/LibraryView.swift`, `BookLibraryCard` (card on `glassSurface(cornerRadius: ReadingMetrics.Radius.card)`; progress line → `DottedProgressRow`)
- Modify: `FinishedBookTimeline.swift`, `PersonalReviewsView.swift`, `HealthView.swift`, `SettingsView.swift`, `HistoryView.swift`, `AppearancePicker.swift` (their `ReadingSection`s pass `glass: true`; History’s pollen alpha × 0.5 through `GardenLayout.pollenScale`)
- Modify: `Sources/BooksPresence/NativeChrome.swift` (`NativeDashboardWindowBackground`: on macOS 26, `containerBackground(for: .window) { GardenCanvas(...) }` so the system sidebar glass samples the garden; on macOS 13–25 the garden stays in the detail column)

- [ ] **Step 1: Write the failing check.** Extend the `UISmoke` layout loop to render every `DashboardSection` with the Garden on, in both appearances, at 1180×820 and 920×660, and assert that no `ReadingSection` text sits outside a glass card. A debug environment flag records the frames of bare `Text` in a `PreferenceKey` (`BareTextFrames`); assert it’s empty outside the header clearing.
- [ ] **Step 2: Build; expect failure** (sections on canvas report bare text).
- [ ] **Step 3: Implement the screen edits above.** `BareTextFrames` is only collected when the `nativePreviewOpaque` debug environment is set, so it costs nothing in production.
- [ ] **Step 4: Run `check-local.sh`, render all screens with `--vine-time 6`, and review them.**
- [ ] **Step 5: Commit** with the message `Put every dashboard screen on the garden`.

### Task 7: Sheets and the menu bar panel

**Files:**
- Modify: `Sources/BooksPresence/PopoverView.swift` (panel content on glass; a `GardenCanvas` with `GardenLayout(roots: 0, pollen: false)` plus one corner tip from the top-right, budget 700; the goal indicator uses the dotted ring style via `ReadingProgress` at compact size, or `DottedProgressRow`)
- Modify: `Sources/BooksPresence/DashboardView.swift` (sheet content gets `.background(GardenCanvas(layout: …sheet size…, mode:))` with a header clearing; `.id(theme.revision)` re-keys render-only sheet content so colours repaint. This is the deferred “sheets don’t repaint on theme change” fix; draft-owning sheets keep identity.)
- Modify: `GardenLayout` (`cornerRoots: [GardenCorner]`, budget override)

- [ ] **Step 1: Write the failing check.** `--render-ui` previews `popover` and `book-detail` must differ from a Garden-off render. Add the `UISmoke` assertion that `GardenLayout(roots: 0, cornerRoots: [.topTrailing])` grows only within 12 cells of that corner’s edges (via a pure `VineField` built from the layout).
- [ ] **Step 2: Build; expect failure.**
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run checks and renders.**
- [ ] **Step 5: Commit, then open PR 2** with the message `Grow the garden in sheets and the menu bar panel`.

---

## Phase 3: Reader margin garden (PR `reader/margin-garden`)

### Task 8: `vines.js`, the engine port, plus unit tests

**Files:**
- Create: `Reader/desktop/reader/src/vines.js`: exports `createField({columns, rows, cellWidth, cellHeight, seed, maxCells})` returning `{cells, budget, allows, plant(spec), step(), growToCompletion(limit), get isGrowing(), heads()}`, and `vinePalette({accent, ink, chart, canvas}, dark)`
- Create: `Reader/desktop/reader/test/vines.test.mjs` (pure Node, no browser)

- [ ] **Step 1: Write the failing tests.** These mirror Task 1’s smoke: determinism, masks, budget prefix, gap-free stems, path followers. Also add cross-language parity: the same seed and plants give the same first 50 stem cells as the Swift model, compared against a fixture `test/fixtures/vine-parity.json` that the Swift smoke writes when run with `--write-parity`.
- [ ] **Step 2: Run** `node --test test/vines.test.mjs` and confirm it fails.
- [ ] **Step 3: Implement it** by porting the mockup `Scene` model functions (`wander`, `followPath`, `sprout`, `finish`, `put`) with identical constants and random-number order. Produce the parity fixture from Swift by adding `--write-parity <path>` to `vine-field-smoke`.
- [ ] **Step 4: Run it and confirm it passes.**
- [ ] **Step 5: Commit** with the message `Port the vine model to the reader`.

### Task 9: `garden.js`, margins, spine, scrolling and adjustable margins

**Files:**
- Create: `Reader/desktop/reader/src/garden.js`: `installGarden({viewport, reader, footer, getPreferences, getProgress, effectiveColumns, readingMargins, onScrollTarget})` returning `{update(reason), setMode(mode), destroy()}`
- Modify: `Reader/desktop/reader/index.html` (a `<canvas id="garden" aria-hidden="true">` before `#reading-viewport`, and `<canvas id="garden-spine" aria-hidden="true">` inside it)
- Modify: `Reader/desktop/reader/src/reader.css` (both canvases `position: fixed` / `absolute`, `pointer-events: none`, `z-index` below the viewport and above it for the spine; the footer gets the glass treatment)
- Modify: `Reader/desktop/reader/src/state.js` (`vines: 'margins'|'off'`, default `margins`)
- Modify: `Reader/desktop/reader/src/main.js` (call `installGarden` after layout; call `update('layout')` from preference changes for margins, sideMargin, contentWidth, columns, scroll, immersive and theme; call `update('progress')` on locator changes; add a Vines radiogroup in the Appearance panel next to Page width and Side margins)
- Modify: `Sources/BooksCore/ReaderStateValidation.swift` (accept `vines` ∈ {`margins`, `off`})
- Modify: `scripts/reader-state-smoke.swift` (round-trip `vines`)
- Create: `Reader/desktop/reader/test/garden.test.mjs`

- [ ] **Step 1: Write the failing Playwright tests.** Use the harness from `appearance-controls.test.mjs`: a local server for `dist/`, a synthetic chapter, Chrome or WebKit chosen by `READER_TEST_BROWSER`.
  - **Single page, 1400×900:** the garden canvas reports `window.StillleafReader.gardenDebug().cells.length > 0` after `growToCompletion`, and no reported cell rect intersects `#reading-viewport`’s rect inset by `--page-inset`.
  - **Facing pages:** spine cells exist, and every one lies inside the column gap (`viewport center ± pageGutter`).
  - **No margins** (Review focus 4): viewport 900×700, `contentWidth: 100`, `margins: 'narrow'` → `gardenDebug().cells.length === 0` and no console errors.
  - **Continuous scroll:** set `scroll: true`, dispatch `page.mouse.wheel(0, 600)` with the pointer over the left margin, and assert the reader’s scroll position changed. During the wheel burst `gardenDebug().frozen === true`; 400 ms later it’s `false`.
  - **Adjustable margins:** change `contentWidth` from 100 to 60 and assert the garden cell count increases, with no layout shift of `#reader` beyond the width change itself (compare `getBoundingClientRect().top`).
  - **Off:** `setPreferences({vines: 'off'})` → zero cells, and no `requestAnimationFrame` callbacks for 500 ms (wrap `requestAnimationFrame` in a counter before load).
- [ ] **Step 2: Build the reader** (`npm --prefix Reader/desktop/reader run build`) and run `node --test test/garden.test.mjs`. Expect failure.
- [ ] **Step 3: Implement `garden.js`.**
  - Geometry comes from `viewport.getBoundingClientRect()`, `readingMargins().gutter` and `effectiveColumns()`.
  - The margin mask refuses the viewport rect plus one cell, the reader bar and the footer. A margin narrower than 7 cells is refused entirely.
  - The spine field exists only when `effectiveColumns() === 2`. It’s confined to `centerX ± (gutter − cellWidth)` and is a path follower from the bottom of the text area to `top + (1 − progress) · height`.
  - Budget is `max(24, round(1500 · chapterProgress))`. Progress changes use the replay `regrow` from the mockup: existing cells stay, new cells fade in staggered by 7 ms, removed cells fade out.
  - Scrolling: listen with `{passive: true, capture: true}` for `wheel` and `scroll` on `window` and the reader’s frames (the existing `backgroundActivity` hook). Set `frozen = true` and cancel `requestAnimationFrame`; resume 300 ms after the last event. Progress regrowth is applied only when unfrozen.
  - Animation runs only while `document.visibilityState === 'visible'`. `prefers-reduced-motion` gives a still render.
  - The palette comes from the reader theme’s computed `--accent`, `--ink` and `--paper`. Dark is detected by `--paper` luminance below 0.4.
  - Expose `gardenDebug()` on `window.StillleafReader` only when `?debug-garden` is in the URL or tests set `window.__stillleafGardenDebug = true` before load.
- [ ] **Step 4: Run** `garden.test.mjs` in Chrome and in WebKit (`READER_TEST_BROWSER=webkit`), the full reader suite, and `scripts/check-local.sh` (reader-state smoke), then confirm all pass.
- [ ] **Step 5: Commit** with the message `Grow the margin garden in the reader`.

### Task 10: Garden mode from the app, and native verification

**Files:**
- Modify: `Reader/desktop/reader/src/main.js` (`window.StillleafReader.setGardenMode('animated'|'still'|'off')`; `off` hides both canvases, `still` renders the grown state once)
- Modify: `Sources/BooksPresence/EPUBReaderWindow.swift` (after ready and whenever `ThemeStore.shared.revision` changes, call `webView.callAsyncJavaScript("window.StillleafReader.setGardenMode(mode)", arguments: ["mode": ThemeStore.shared.effectiveGardenMode(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion).rawValue], ...)`)
- Modify: `Sources/BooksPresence/EPUBReaderWindow.swift`, smoke section (assert that `gardenDebug` responds and that setting `off` clears cells, on the synthetic fixture)

- [ ] **Step 1: Add the failing native smoke assertion** inside `runEPUBReaderSmoke`: after the window is ready, evaluate `window.__stillleafGardenDebug=true` before load (inject a `WKUserScript` in smoke mode only), call `setGardenMode('off')`, and assert `gardenDebug().cells.length === 0`.
- [ ] **Step 2: Build and run** `.build/tidy/BooksPresence --self-test-epub <fixture>` (fixture from `python3 scripts/reader-review-fixture.py`). Expect failure.
- [ ] **Step 3: Implement the bridge.**
- [ ] **Step 4: Run the native smoke** in paginated and continuous modes (`--reader-experimental-continuous`) and on one real book from `~/Downloads/Books/Ebooks/Reading List Downloads/`. Make sure the lid is open, since a closed lid causes flaky stalls.
- [ ] **Step 5: Commit, then open PR 3.**

---

## Phase 4: Empty states, completion and onboarding (PR `ui/garden-moments`)

### Task 11: Seedling empty state and completion burst

**Files:**
- Create: `Sources/BooksPresence/Vines/VineSeedling.swift`: the hand-drawn seedling (7 rows, from the mockup), revealed in growth order: ground, then upward from the stem outward, with the bloom last at 110 ms per glyph. It holds for 5.2 s, fades and regrows (animated only).
- Create: `Sources/BooksPresence/Vines/VineBurst.swift`: 12 wandering tips from an ellipse around a centre rect, alternating curl ±0.07, life 14…24, branch 0.12, bloom 1.0, with spores. `replay()` restarts it.
- Modify: `Sources/BooksPresence/ReadingLayout.swift` (`ReadingEmptyState` shows `VineSeedling` above its title instead of the SF Symbol when the Garden isn’t off)
- Modify: `Sources/BooksPresence/CompletionCelebration.swift` (the badge gets a `VineBurst` behind it; the old confetti is removed; the `moss`/`ochre` alias usage is already gone)

- [ ] **Step 1: Write the failing smoke.** `VineSeedling.glyphOrder` (static) lists ground glyphs before stem glyphs and `❀` last. Rendering `VineBurst` grown to completion inside a 400×300 frame with a 200×80 centre leaves no cell inside the centre rect.
- [ ] **Step 2: Build; expect failure.**
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run checks and render** `today-empty`, `finished-prompt`, `written-review` and the completion previews.
- [ ] **Step 5: Commit** with the message `Plant seedlings in empty states and flower on completion`.

### Task 12: Onboarding garden

**Files:**
- Modify: `Sources/BooksPresence/Onboarding.swift`: replace the 30 fps `TimelineView` backdrop (`:334`) with `GardenCanvas`, whose budget is `2400 × (step index + 1) / step count`, regrowing with the replay rule as steps advance. Remove the two infinite animations (`:462`, `:924`), and use `ReadingMotion` springs instead of the 0.62-damping spring (`:962`).

- [ ] **Step 1: Write the failing smoke.** The existing onboarding smoke asserts each step’s garden budget is strictly greater than the previous step’s, and that the final step reaches 2,400.
- [ ] **Step 2: Build; expect failure.**
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run** `check-local.sh` and render `onboarding-1…6`. With `--vine-time 6`, the renders must be identical across two runs; previously they varied by 5–20% because the backdrop animates.
- [ ] **Step 5: Commit, then open PR 4.**

---

## Self-review notes

- Spec coverage: design rules 1–5 → Tasks 3, 4, 5, 6, 9. Visual language → 2, 5. Engine → 1, 4, 8. Dashboard → 5, 6, 7. Reader → 8, 9, 10. Scrolling and input → 9. Native architecture → 1–5. Testing → every task. Phases → PR boundaries above.
- **Deviation from the spec:** the reader derives its vine palette from the *reader’s* page theme (`--accent`, `--ink`, `--paper`) rather than receiving the app accent. The garden must contrast with the paper the reader actually shows, and this avoids a theme bridge. The global Garden mode still crosses the bridge (Task 10).

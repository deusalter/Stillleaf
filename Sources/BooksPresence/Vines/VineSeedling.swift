import SwiftUI

/// A hand-drawn seedling for empty states: revealed from the ground up, stem
/// first and bloom last, then held, faded and regrown while animated. It only
/// ticks while revealing and fading, and not at all while its window is hidden.
struct VineSeedling: View {
    static let art = [
        "     ❀     ",
        "  @  │  @  ",
        "   ╲ │ ╱   ",
        " {  ╲│╱  } ",
        "  ╲__│__╱  ",
        "     │     ",
        "  ───┴───  "
    ]

    struct Glyph: Equatable {
        let x: Int
        let y: Int
        let glyph: Character
        var kind: VineKind { glyph == "❀" ? .bloom : "@{}".contains(glyph) ? .leaf : .stem }
    }

    /// Ground first, then upward from the stem outwards; the bloom opens last.
    static let glyphOrder: [Glyph] = {
        let middle = Double(art[0].count - 1) / 2
        var glyphs: [Glyph] = []
        for (y, line) in art.enumerated() {
            for (x, glyph) in line.enumerated() where glyph != " " { glyphs.append(Glyph(x: x, y: y, glyph: glyph)) }
        }
        return glyphs.sorted { a, b in
            if a.kind == .bloom || b.kind == .bloom { return b.kind == .bloom && a.kind != .bloom }
            let rank = { (g: Glyph) in Double(g.y) * 10 - abs(Double(g.x) - middle) }
            return rank(a) > rank(b)
        }
    }()

    let mode: GardenMode
    @Environment(\.colorScheme) private var colorScheme

    @State private var visible = true

    static let reveal = 0.11, hold = 5.2, fade = 0.9, frameInterval = 1.0 / 20
    static var cycle: Double { Double(glyphOrder.count) * reveal + hold + fade }
    /// When the last glyph has finished appearing: from here the picture is still until the fade.
    static var revealEnd: Double { Double(glyphOrder.count - 1) * reveal + 0.35 }

    /// The next frame after `time` (seconds, wrapped by `cycle`): 20 fps while
    /// revealing and fading, one frame at the end of the reveal, then a jump
    /// over the hold to the start of the fade.
    static func nextTick(after time: Double) -> Double {
        let position = time.truncatingRemainder(dividingBy: cycle)
        let fadeStart = cycle - fade, epsilon = 1e-6
        if position < revealEnd - epsilon { return time + min(frameInterval, revealEnd - position) }
        if position < fadeStart - epsilon { return time + (fadeStart - position) }
        return time + frameInterval
    }

    /// Every frame from `start` up to `end`, as the timeline schedules them.
    static func ticks(from start: Double, to end: Double) -> [Double] {
        var result: [Double] = [], time = start
        while time <= end { result.append(time); time = nextTick(after: time) }
        return result
    }

    struct Schedule: TimelineSchedule {
        func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries { Entries(upcoming: startDate) }

        struct Entries: Sequence, IteratorProtocol {
            var upcoming: Date
            mutating func next() -> Date? {
                defer { upcoming = Date(timeIntervalSinceReferenceDate: VineSeedling.nextTick(after: upcoming.timeIntervalSinceReferenceDate)) }
                return upcoming
            }
        }
    }

    var body: some View {
        Group {
            if mode == .animated && GardenClock.frozenTime == nil && visible {
                TimelineView(Schedule()) { context in
                    canvas(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle))
                }
            } else {
                canvas(time: Self.revealEnd + 1)
            }
        }
        .background(WindowVisibility(isVisible: $visible))
        .frame(width: GardenModel.cellWidth * Double(Self.art[0].count), height: GardenModel.cellHeight * Double(Self.art.count))
        .accessibilityHidden(true)
    }

    private func canvas(time: Double) -> some View {
        let dark = colorScheme == .dark
        let snapshot = ThemeSnapshot.current()
        let palette = VinePalette.make(dark ? snapshot.dark : snapshot.light, dark: dark)
        return Canvas { context, _ in
            let fadeOut = 1 - min(1, max(0, (time - (Self.cycle - Self.fade)) / Self.fade))
            for (index, glyph) in Self.glyphOrder.enumerated() {
                let shown = min(1, max(0, (time - Double(index) * Self.reveal) / 0.35))
                guard shown > 0 else { continue }
                var cell = context
                cell.opacity = shown * fadeOut * palette.baseAlpha
                let color = Color(ReadingPalette.nsColor(palette.color(glyph.kind, slot: glyph.kind == .bloom ? 1 : index)))
                cell.draw(Text(String(glyph.glyph)).font(.system(size: 13, design: .monospaced)).foregroundColor(color),
                          at: CGPoint(x: Double(glyph.x) * GardenModel.cellWidth, y: Double(glyph.y) * GardenModel.cellHeight), anchor: .topLeading)
            }
        }
    }
}

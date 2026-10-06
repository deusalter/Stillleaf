import SwiftUI

/// Finishing a book: twelve vines burst outward around the badge, curling in
/// alternate directions, flower, then fade away completely.
struct VineBurst: View {
    /// When the burst started; `nil` draws nothing.
    let start: Date?
    @Environment(\.colorScheme) private var colorScheme

    static let stepsPerSecond = 22.0, holdUntil = 1.7, fadeDuration = 0.8

    /// The fully grown burst for a frame, deterministic for a seed.
    static func field(size: CGSize, around centre: CGRect, seed: UInt32) -> VineField {
        let w = GardenModel.cellWidth, h = GardenModel.cellHeight
        var field = VineField(columns: Int(size.width / w) + 1, rows: Int(size.height / h) + 1, cellWidth: w, cellHeight: h, seed: seed, maxCells: 700)
        let clear = centre.insetBy(dx: -w * 0.5, dy: -h * 0.25)
        field.allows = { x, y in !CGRect(x: Double(x) * w, y: Double(y) * h, width: w, height: h).intersects(clear) }
        let cx = Double(centre.midX) / w, cy = Double(centre.midY) / h
        let rx = Double(centre.width) / w * 0.62, ry = Double(centre.height) / h * 0.9
        var random = VineRandom(seed: seed ^ 0xB5)
        for i in 0..<12 {
            let angle = Double(i) / 12 * 2 * .pi + random.next() * 0.3
            field.plant(VineTipSpec(x: Int((cx + cos(angle) * rx).rounded()), y: Int((cy + sin(angle) * ry).rounded()), heading: angle,
                                    life: 14 + Int(random.next() * 10), curl: (i.isMultiple(of: 2) ? 1 : -1) * 0.07, hue: i,
                                    branchChance: 0.12, leafChance: 0.3, bloomChance: 1, maxGeneration: 2, branchLife: 8))
        }
        field.growToCompletion(limit: 400)
        return field
    }

    var body: some View {
        GeometryReader { proxy in
            if let start {
                let centre = CGRect(x: proxy.size.width / 2 - 16, y: proxy.size.height / 2 - 16, width: 32, height: 32)
                let field = Self.field(size: proxy.size, around: centre, seed: UInt32(truncatingIfNeeded: Int(start.timeIntervalSince1970)))
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSince(start)
                    if elapsed < Self.holdUntil + Self.fadeDuration { canvas(field, elapsed: elapsed) }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func canvas(_ field: VineField, elapsed: Double) -> some View {
        let dark = colorScheme == .dark
        let snapshot = ThemeSnapshot.current()
        let palette = VinePalette.make(dark ? snapshot.dark : snapshot.light, dark: dark)
        let grown = elapsed * Self.stepsPerSecond
        let fade = 1 - min(1, max(0, (elapsed - Self.holdUntil) / Self.fadeDuration))
        return Canvas { context, _ in
            for cell in field.cells.values {
                let shown = min(1, max(0, (grown - Double(cell.step)) / 4))
                guard shown > 0 else { continue }
                var drawn = context
                drawn.opacity = shown * fade * palette.baseAlpha
                drawn.draw(Text(String(cell.glyph)).font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Color(ReadingPalette.nsColor(palette.color(cell.kind, slot: cell.slot)))),
                           at: CGPoint(x: Double(cell.x) * field.cellWidth, y: Double(cell.y) * field.cellHeight), anchor: .topLeading)
            }
        }
    }
}

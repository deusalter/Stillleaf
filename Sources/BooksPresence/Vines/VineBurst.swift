import SwiftUI

/// Finishing a book: twelve vines burst outward around the badge, curling in
/// alternate directions, flower, then fade away completely. Under Still the
/// grown burst appears at once and fades without redrawing; Off draws nothing.
struct VineBurst: View {
    /// When the burst started; `nil` draws nothing.
    let start: Date?
    var presentation: Presentation = .animated
    @Environment(\.colorScheme) private var colorScheme
    @State private var faded = false

    enum Presentation: Equatable { case none, still, animated }

    static let stepsPerSecond = 22.0, holdUntil = 1.7, fadeDuration = 0.8, stillHold = 1.2, frameInterval = 1.0 / 30

    static func presentation(for mode: GardenMode) -> Presentation {
        switch mode {
        case .off: return .none
        case .still: return .still
        case .animated: return .animated
        }
    }

    /// Seconds from `start` until nothing of the burst is left.
    static func duration(for presentation: Presentation) -> Double {
        switch presentation {
        case .none: return 0
        case .still: return stillHold + fadeDuration
        case .animated: return holdUntil + fadeDuration
        }
    }

    /// Frames for the animated burst, ending with the first one after it has
    /// faded, so the timeline stops by itself instead of running until the
    /// owner removes the view.
    struct Schedule: TimelineSchedule {
        let start: Date

        func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries { Entries(start: start, from: startDate) }

        struct Entries: Sequence, IteratorProtocol {
            let start: Date
            var upcoming: Date?

            init(start: Date, from: Date) {
                self.start = start
                upcoming = from
            }

            mutating func next() -> Date? {
                guard let current = upcoming else { return nil }
                let end = start.addingTimeInterval(VineBurst.duration(for: .animated))
                upcoming = current >= end ? nil : Swift.min(current.addingTimeInterval(VineBurst.frameInterval), end)
                return current
            }
        }
    }

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
            if let start, presentation != .none {
                let centre = CGRect(x: proxy.size.width / 2 - 16, y: proxy.size.height / 2 - 16, width: 32, height: 32)
                let field = Self.field(size: proxy.size, around: centre, seed: UInt32(truncatingIfNeeded: Int(start.timeIntervalSince1970)))
                if presentation == .animated {
                    TimelineView(Schedule(start: start)) { context in
                        let elapsed = context.date.timeIntervalSince(start)
                        if elapsed < Self.duration(for: .animated) { canvas(field, grown: elapsed * Self.stepsPerSecond, elapsed: elapsed) }
                    }
                } else {
                    // One drawn frame; the fade is a layer opacity animation.
                    canvas(field, grown: .infinity, elapsed: 0).opacity(faded ? 0 : 1)
                }
            }
        }
        .task(id: start) {
            faded = false
            guard start != nil, presentation == .still else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.stillHold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Self.fadeDuration)) { faded = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func canvas(_ field: VineField, grown: Double, elapsed: Double) -> some View {
        let dark = colorScheme == .dark
        let snapshot = ThemeSnapshot.current()
        let palette = VinePalette.make(dark ? snapshot.dark : snapshot.light, dark: dark)
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

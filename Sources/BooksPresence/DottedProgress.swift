import SwiftUI

/// A straight row of dots that fills from the leading edge, matching the daily
/// goal ring: track-coloured dots, accent fill and a smooth leading dot.
struct DottedProgressRow: View {
    let fraction: Double
    var dots = 36
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(fraction: Double, dots: Int = 36) {
        self.fraction = fraction
        self.dots = dots
    }

    var body: some View {
        Canvas { context, size in
            let filled = min(1, max(0, fraction))
            let diameter = min(7, size.height)
            let step = dots > 1 ? (size.width - diameter) / Double(dots - 1) : 0
            for index in 0..<dots {
                let dot = Path(ellipseIn: CGRect(x: Double(index) * step, y: (size.height - diameter) / 2, width: diameter, height: diameter))
                context.fill(dot, with: .color(ReadingPalette.track))
                let coverage = min(1, max(0, filled * Double(dots) - Double(index)))
                if coverage > 0 { context.fill(dot, with: .color(ReadingPalette.accent.opacity(coverage))) }
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(1, max(0, fraction)) * 100).rounded())) percent")
    }
}

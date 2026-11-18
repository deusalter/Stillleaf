import SwiftUI

/// The small botanical plate in Appearance. Its outline and veins share the active accent.
/// Only the finished drawing sways, so animation does not redraw the paths every frame.
struct FieldGuideFronds: View {
    let ink: Color
    let wash: Color
    let animated: Bool
    @State private var swaying = false

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 290, y: size.height / 146)
            context.fill(Self.plate.leaves, with: .color(wash))
            context.stroke(Self.plate.leaves, with: .color(ink), lineWidth: 0.8)
            context.stroke(Self.plate.lines, with: .color(ink), lineWidth: 0.65)
        }
        .rotationEffect(.degrees(swaying ? 1.3 : -0.6), anchor: .bottom)
        .onAppear { updateSway() }
        .onChange(of: animated) { _ in updateSway() }
    }

    private func updateSway() {
        withAnimation(animated ? .easeInOut(duration: 4).repeatForever(autoreverses: true) : nil) {
            swaying = animated
        }
    }

    private static let plate: (leaves: Path, lines: Path) = {
        var leaves = Path()
        var lines = Path()

        // Each leaflet is a unit shape pointing right. Stamp it along a curved stem.
        var leaf = Path()
        leaf.move(to: .zero)
        leaf.addQuadCurve(to: CGPoint(x: 1, y: 0), control: CGPoint(x: 0.45, y: -0.34))
        leaf.addQuadCurve(to: .zero, control: CGPoint(x: 0.55, y: 0.32))
        leaf.closeSubpath()
        var veins = Path()
        veins.move(to: .zero)
        veins.addLine(to: CGPoint(x: 0.96, y: 0))
        for index in 1...5 {
            let t = CGFloat(index) / 7
            let height = sin(t * .pi) * 0.125
            for side: CGFloat in [-1, 1] {
                veins.move(to: CGPoint(x: t, y: 0))
                veins.addLine(to: CGPoint(x: t + 0.12, y: side * height))
            }
        }

        func leaflet(at point: CGPoint, angle: CGFloat, length: CGFloat) {
            let transform = CGAffineTransform(translationX: point.x, y: point.y)
                .rotated(by: angle).scaledBy(x: length, y: length)
            leaves.addPath(leaf, transform: transform)
            lines.addPath(veins, transform: transform)
        }

        func sprig(x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat, bend: CGFloat, pairs: Int, length: CGFloat) {
            func point(_ t: CGFloat) -> CGPoint {
                CGPoint(x: x + dx * t + bend * sin(.pi * t), y: y + dy * t)
            }
            func angle(_ t: CGFloat) -> CGFloat { atan2(dy, dx + .pi * bend * cos(.pi * t)) }
            lines.move(to: point(0))
            for step in 1...32 { lines.addLine(to: point(CGFloat(step) / 32)) }
            for index in 1...pairs {
                let t = 0.15 + 0.76 * CGFloat(index) / CGFloat(pairs + 1)
                for side: CGFloat in [-1, 1] {
                    leaflet(at: point(t + (side > 0 ? 0.025 : 0)), angle: angle(t) + side * 0.85,
                            length: length * (1 - 0.48 * t))
                }
            }
            leaflet(at: point(0.97), angle: angle(1), length: length * 0.53)
        }
        sprig(x: 74, y: 161, dx: -33, dy: -81, bend: -8, pairs: 4, length: 22)
        sprig(x: 89, y: 160, dx: 3, dy: -142, bend: 19, pairs: 7, length: 26)
        sprig(x: 108, y: 160, dx: 76, dy: -130, bend: -20, pairs: 6, length: 28)
        sprig(x: 167, y: 169, dx: 84, dy: -150, bend: 3, pairs: 7, length: 31)
        sprig(x: 204, y: 164, dx: 80, dy: -68, bend: 6, pairs: 4, length: 25)
        return (leaves, lines)
    }()
}

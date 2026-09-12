import AppKit
import SwiftUI

/// Approved Pageleaf geometry in a 100 × 100 coordinate space.
/// Native marks and generated web/Dock assets share these commands.
enum PageleafIdentity {
    static let commands: [(String, [CGFloat])] = [
        ("M", [47, 78]), ("C", [22, 77, 12, 59, 17, 25]),
        ("C", [33, 27, 45, 40, 47, 59]), ("Z", []),
        ("M", [54, 78]), ("C", [53, 48, 64, 24, 86, 14]),
        ("C", [91, 45, 81, 68, 54, 78]), ("Z", [])
    ]

    static var path: CGPath {
        let path = CGMutablePath()
        for (command, v) in commands {
            switch command {
            case "M": path.move(to: CGPoint(x: v[0], y: v[1]))
            case "C": path.addCurve(to: CGPoint(x: v[4], y: v[5]),
                                    control1: CGPoint(x: v[0], y: v[1]),
                                    control2: CGPoint(x: v[2], y: v[3]))
            default: path.closeSubpath()
            }
        }
        return path
    }

    static var svgPath: String {
        commands.map { command, values in
            command + values.map { String(Int($0)) }.joined(separator: " ")
        }.joined()
    }

    static var statusImage: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: bounds.width / 100, y: bounds.height / 100)
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Stillleaf reading tracker"
        return image
    }
}

/// Decorative brand mark; the adjacent Stillleaf label supplies accessibility text.
struct PageleafMark: View {
    var body: some View {
        PageleafShape().accessibilityHidden(true)
    }
}

private struct PageleafShape: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        var transform = CGAffineTransform(translationX: rect.midX - size / 2, y: rect.midY - size / 2)
            .scaledBy(x: size / 100, y: size / 100)
        return Path(PageleafIdentity.path.copy(using: &transform)!)
    }
}

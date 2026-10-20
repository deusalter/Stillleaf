import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the iOS App Store icon: the Mac's Pageleaf artwork, full bleed and opaque
// (iOS applies its own mask and rejects alpha). Usage: swift generate-app-icon.swift <output.png>
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Draw in the Mac generator's y-down tile space, where the 236-unit tile now fills the canvas.
let scale = CGFloat(size) / 236
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: scale, y: -scale)
let gradient = CGGradient(colorsSpace: space, colors: [
    CGColor(srgbRed: 23 / 255, green: 102 / 255, blue: 80 / 255, alpha: 1),
    CGColor(srgbRed: 18 / 255, green: 62 / 255, blue: 50 / 255, alpha: 1)
] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 189, y: 236),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// The Mac places the 100-unit mark at (51, 44) × 1.58 inside a tile offset by (10, 8).
context.translateBy(x: 41, y: 36)
context.scaleBy(x: 1.58, y: 1.58)
let leaf = CGMutablePath()
leaf.move(to: CGPoint(x: 47, y: 78))
leaf.addCurve(to: CGPoint(x: 17, y: 25), control1: CGPoint(x: 22, y: 77), control2: CGPoint(x: 12, y: 59))
leaf.addCurve(to: CGPoint(x: 47, y: 59), control1: CGPoint(x: 33, y: 27), control2: CGPoint(x: 45, y: 40))
leaf.closeSubpath()
leaf.move(to: CGPoint(x: 54, y: 78))
leaf.addCurve(to: CGPoint(x: 86, y: 14), control1: CGPoint(x: 53, y: 48), control2: CGPoint(x: 64, y: 24))
leaf.addCurve(to: CGPoint(x: 54, y: 78), control1: CGPoint(x: 91, y: 45), control2: CGPoint(x: 81, y: 68))
leaf.closeSubpath()
context.addPath(leaf)
context.setFillColor(CGColor(srgbRed: 1, green: 249 / 255, blue: 234 / 255, alpha: 1))
context.fillPath()
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(output.path)") }
print("Wrote \(output.path)")

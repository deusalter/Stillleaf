import AppKit

@main
struct GeneratePageleaf {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let out = root.appendingPathComponent(".build/Pageleaf.iconset")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func render(_ pixels: Int) -> Data {
            let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: 0, y: CGFloat(pixels))
            context.scaleBy(x: CGFloat(pixels) / 256, y: -CGFloat(pixels) / 256)
            let tile = CGPath(roundedRect: CGRect(x: 10, y: 8, width: 236, height: 236),
                              cornerWidth: 53, cornerHeight: 53, transform: nil)
            context.saveGState()
            context.addPath(tile); context.clip()
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                NSColor(srgbRed: 23/255, green: 102/255, blue: 80/255, alpha: 1).cgColor,
                NSColor(srgbRed: 18/255, green: 62/255, blue: 50/255, alpha: 1).cgColor
            ] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: 10, y: 8), end: CGPoint(x: 199, y: 244), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
            context.addPath(tile)
            context.setStrokeColor(NSColor(white: 1, alpha: 0.22).cgColor)
            context.setLineWidth(1); context.strokePath()
            context.translateBy(x: 51, y: 44); context.scaleBy(x: 1.58, y: 1.58)
            context.addPath(PageleafIdentity.path)
            context.setFillColor(NSColor(srgbRed: 1, green: 249/255, blue: 234/255, alpha: 1).cgColor)
            context.fillPath()
            return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        }
        for size in [16, 32, 128, 256, 512] {
            try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
            try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
        }
        try render(1024).write(to: root.appendingPathComponent("assets/BooksPresence.png"))
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" fill="currentColor" style="color:#176650"><style>@media(prefers-color-scheme:dark){:root{color:#6fd4ae}}</style><path id="pageleaf" d="\(PageleafIdentity.svgPath)"/></svg>
        """
        for relative in ["assets/Pageleaf.svg", "website/public/leaf.svg", "Reader/desktop/src/pageleaf.svg", "Reader/desktop/reader/public/pageleaf.svg"] {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(svg.utf8).write(to: url)
        }
        try render(512).write(to: root.appendingPathComponent("Reader/desktop/src/pageleaf.png"))
        print("Generated Pageleaf SVGs, PNGs and iconset")
    }
}

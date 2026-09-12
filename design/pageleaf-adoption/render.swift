import AppKit
import SwiftUI

private let green = Color(red: 23/255, green: 102/255, blue: 80/255)
struct Preview: View {
    let root: String
    @ViewBuilder func mark(_ after: Bool, size: CGFloat) -> some View {
        if after { PageleafMark().frame(width: size, height: size) }
        else { Image(systemName: "leaf.fill").font(.system(size: size * 0.72, weight: .medium)).frame(width: size, height: size) }
    }
    func column(_ after: Bool) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(after ? "After · Pageleaf" : "Before · mixed identity").font(.system(size: 25, design: .serif))
            HStack(spacing: 32) {
                Image(nsImage: NSImage(contentsOfFile: root + (after ? "/assets/BooksPresence.png" : "/design/pageleaf-adoption/before-dock.png"))!)
                    .resizable().frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 12) {
                    Text("App / Dock").font(.headline)
                    Text(after ? "Approved green tile\nTransparent corners\n16–1024 px" : "Plum book illustration\nSeparate from the dashboard leaf")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Dashboard & popover").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 9) {
                mark(after, size: 23).foregroundStyle(green)
                Text("Stillleaf").font(.system(size: 21, design: .serif))
                Spacer()
                mark(after, size: 18).foregroundStyle(green)
                Text("Stillleaf").font(.system(size: 16, design: .serif))
            }.padding(18).background(Color(red: 0.92, green: 0.95, blue: 0.93), in: RoundedRectangle(cornerRadius: 12))
            Text("Menu bar · template, light and dark").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach([false, true], id: \.self) { dark in
                    HStack(spacing: 18) {
                        Image(systemName: "wifi")
                        Image(nsImage: after ? PageleafIdentity.statusImage : NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)!)
                            .renderingMode(.template)
                        Text("9:41").font(.system(size: 12))
                    }.foregroundStyle(dark ? .white : .black).padding(16)
                        .background(dark ? Color(red: 0.08, green: 0.12, blue: 0.10) : Color(red: 0.92, green: 0.94, blue: 0.92), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Text("Walkthrough · only the mark changes").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                ZStack {
                    ForEach(0..<3) { ring in
                        Circle().strokeBorder(green.opacity(0.22 - Double(ring) * 0.06), lineWidth: 1)
                            .frame(width: 104 + CGFloat(ring)*36, height: 104 + CGFloat(ring)*36)
                    }
                    Circle().fill(LinearGradient(colors: [green, green.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 88, height: 88)
                        .shadow(color: green.opacity(0.35), radius: 22, x: 0, y: 10)
                    mark(after, size: 50).foregroundStyle(.white).rotationEffect(.degrees(3))
                }.frame(width: 180, height: 180)
                Text("Welcome to Stillleaf").font(.system(size: 25, design: .serif))
            }
        }.padding(28).frame(width: 580).background(.white, in: RoundedRectangle(cornerRadius: 20))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Stillleaf · approved identity adoption").font(.system(size: 35, design: .serif))
            Text("Native component study — actual vector and shipped icon assets. No running app modified.").font(.system(size: 14)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) { column(false); column(true) }
        }.padding(32).background(Color(red: 0.96, green: 0.97, blue: 0.95))
    }
}
@main
struct Render {
    @MainActor static func main() throws {
        let root = CommandLine.arguments[1]
        let renderer = ImageRenderer(content: Preview(root: root))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Render failed") }
        try png.write(to: URL(fileURLWithPath: root + "/design/pageleaf-adoption/before-after.png"))
        print("Rendered native identity preview")
    }
}

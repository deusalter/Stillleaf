import SwiftUI
import BooksCore

struct BookCoverView: View {
    enum Size { case compact, menu, large, library, shelf, shelfLarge, hero, timeline, annual }
    let book: BookRecord?
    let size: Size
    @State private var thumbnail: NSImage?

    private var dimensions: CGSize {
        switch size {
        case .compact: return CGSize(width: 52, height: 72)
        case .menu: return CGSize(width: 62, height: 88)
        case .shelf: return CGSize(width: 108, height: 154)
        case .large: return CGSize(width: 104, height: 148)
        case .library: return CGSize(width: 72, height: 104)
        case .shelfLarge: return CGSize(width: 150, height: 225)
        case .hero: return CGSize(width: 132, height: 198)
        case .timeline: return CGSize(width: 64, height: 96)
        case .annual: return CGSize(width: 92, height: 138)
        }
    }

    /// Covers without a title look the same for every book, so one cached bitmap stands in.
    private var sharedPlaceholder: Bool { size == .compact || size == .menu || size == .timeline }

    var body: some View {
        Group {
            if let image = thumbnail {
                Image(nsImage: image).resizable().scaledToFill()
            } else if sharedPlaceholder {
                Image(nsImage: CoverPlaceholder.image(size: dimensions))
            } else {
                ZStack {
                    ReadingPalette.elevated
                    HStack(spacing: 0) {
                        Rectangle().fill(ReadingPalette.accent.opacity(0.3)).frame(width: 6)
                        Rectangle().fill(ReadingPalette.ink.opacity(0.08)).frame(width: 1)
                        Spacer()
                    }
                    VStack(spacing: 8) {
                        Image(systemName: "book.closed")
                            .font(.system(size: max(16, dimensions.width * 0.22), weight: .light))
                        if size != .compact && size != .menu && size != .timeline {
                            Text(book?.title ?? "Your next read")
                                .font(.system(size: size == .large || size == .hero || size == .shelfLarge ? 14 : 11, weight: .medium, design: .serif))
                                .multilineTextAlignment(.center).lineLimit(3)
                        }
                    }
                    .foregroundStyle(ReadingPalette.ink.opacity(0.78))
                    .padding(.leading, 7).padding(8)
                }
            }
        }
        .frame(width: dimensions.width, height: dimensions.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(ReadingPalette.ink.opacity(0.13)))
        .modifier(CoverLoader(path: book?.coverPath, thumbnail: $thumbnail))
        .accessibilityLabel(book?.coverPath == nil ? "Cover unavailable" : "Book cover")
    }
}

/// Loads a cover's thumbnail. A book without a cover starts no task at all, which matters
/// when a screen shows dozens of them.
private struct CoverLoader: ViewModifier {
    let path: String?
    @Binding var thumbnail: NSImage?

    @ViewBuilder func body(content: Content) -> some View {
        if let path {
            content.task(id: path) {
                if thumbnail != nil { thumbnail = nil }
                let image = await CoverThumbnails.shared.image(at: path)
                guard !Task.isCancelled else { return }
                thumbnail = image
            }
        } else {
            content.onAppear { if thumbnail != nil { thumbnail = nil } }
        }
    }
}

/// The title-less placeholder cover, drawn once per size. It paints with the current
/// appearance and theme each time it is displayed, so it follows both.
@MainActor
enum CoverPlaceholder {
    private static var images: [String: NSImage] = [:]

    static func image(size: CGSize) -> NSImage {
        let key = "\(size.width)x\(size.height)"
        if let cached = images[key] { return cached }
        let image = NSImage(size: size, flipped: false) { rect in
            let snapshot = ThemeSnapshot.current()
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let colors = dark ? snapshot.dark : snapshot.light
            ReadingPalette.nsColor(colors.elevated).setFill(); rect.fill()
            ReadingPalette.nsColor(colors.accent).withAlphaComponent(0.3).setFill()
            NSRect(x: 0, y: 0, width: 6, height: rect.height).fill()
            ReadingPalette.nsColor(colors.ink).withAlphaComponent(0.08).setFill()
            NSRect(x: 6, y: 0, width: 1, height: rect.height).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: max(16, rect.width * 0.22), weight: .light)
            if let symbol = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let ink = ReadingPalette.nsColor(colors.ink).withAlphaComponent(0.78)
                let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
                    symbol.draw(in: bounds)
                    ink.set(); bounds.fill(using: .sourceAtop)
                    return true
                }
                // Centred in the area right of the spine, as the stacked layout it replaces was.
                tinted.draw(at: NSPoint(x: (rect.width + 7) / 2 - symbol.size.width / 2, y: rect.height / 2 - symbol.size.height / 2),
                            from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        images[key] = image
        return image
    }
}

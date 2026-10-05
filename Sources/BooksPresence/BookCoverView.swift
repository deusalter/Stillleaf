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

    var body: some View {
        Group {
            if let image = thumbnail {
                Image(nsImage: image).resizable().scaledToFill()
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
        .task(id: book?.coverPath) {
            thumbnail = nil
            guard let path = book?.coverPath else { return }
            let image = await CoverThumbnails.shared.image(at: path)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
        .accessibilityLabel(book?.coverPath == nil ? "Cover unavailable" : "Book cover")
    }
}

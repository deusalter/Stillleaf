import SwiftUI
import UniformTypeIdentifiers
import BooksCore

/// The Pageleaf mark: the same eight path commands as the Mac's `PageleafIdentity`, in a 100 × 100 space.
struct PageleafMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 100
        let origin = CGPoint(x: rect.midX - 50 * scale, y: rect.midY - 50 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        var path = Path()
        path.move(to: point(47, 78))
        path.addCurve(to: point(17, 25), control1: point(22, 77), control2: point(12, 59))
        path.addCurve(to: point(47, 59), control1: point(33, 27), control2: point(45, 40))
        path.closeSubpath()
        path.move(to: point(54, 78))
        path.addCurve(to: point(86, 14), control1: point(53, 48), control2: point(64, 24))
        path.addCurve(to: point(54, 78), control1: point(91, 45), control2: point(81, 68))
        path.closeSubpath()
        return path
    }
}

struct GoalRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: fraction)
        }
        .accessibilityElement()
        .accessibilityLabel("Daily goal")
        .accessibilityValue("\(Int((min(1, fraction) * 100).rounded())) percent")
    }
}

/// A book cover from the imported edition, or a quiet generated tile.
struct BookCover: View {
    let book: BookRecord
    let coverURL: URL?
    var maxPixels = 360
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 6) {
                    PageleafMark().fill(.white.opacity(0.85)).frame(width: 22, height: 22)
                    Text(book.title)
                        .font(.system(.caption, design: .serif).weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .minimumScaleFactor(0.7)
                }
                .padding(8)
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
        .accessibilityHidden(true)
        .task(id: coverURL) {
            guard let coverURL else { image = nil; return }
            image = CoverThumbnails.shared.cached(coverURL, maxPixels: maxPixels)
            if image == nil { image = await CoverThumbnails.shared.load(coverURL, maxPixels: maxPixels) }
        }
    }
}

struct StarRatingLabel: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5) { index in
                let fill = min(1, max(0, rating - Double(index)))
                Image(systemName: fill >= 0.75 ? "star.fill" : fill >= 0.25 ? "star.leadinghalf.filled" : "star")
            }
        }
        .font(.caption)
        .foregroundStyle(Color.accentColor)
        .accessibilityElement()
        .accessibilityLabel("Rated \(rating.formatted()) out of 5")
    }
}

/// Quarter-star ratings, as on the Mac.
struct RatingEditor: View {
    let rating: Double?
    let save: (Double?) -> Void
    @State private var draft: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StarRatingLabel(rating: draft).font(.title3)
                Spacer()
                Text(rating == nil ? "Not rated" : ReadingText.stars(draft)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $draft, in: 0...5, step: 0.25)
                .accessibilityLabel("Rating")
            if rating != nil {
                Button("Clear Rating", role: .destructive) { save(nil) }.font(.footnote)
            }
        }
        .onAppear { draft = rating ?? 0 }
        .onChange(of: rating) { _, value in draft = value ?? 0 }
        // Saves once the value settles, for drags and VoiceOver adjustments alike.
        .task(id: draft) {
            guard draft != (rating ?? 0) else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { save(draft) }
        }
    }
}

/// Opens an edition in the full-screen reader, from any tab.
struct OpenBookAction {
    let open: (Edition) -> Void
    func callAsFunction(_ edition: Edition) { open(edition) }
}

private struct OpenBookKey: EnvironmentKey {
    static let defaultValue = OpenBookAction { _ in }
}

extension EnvironmentValues {
    var openBook: OpenBookAction {
        get { self[OpenBookKey.self] }
        set { self[OpenBookKey.self] = newValue }
    }
}

/// A file or folder written by the journal, handed to the system exporter.
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.json, .folder, .stillleafBackup, .data] }
    let url: URL

    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}

extension UTType {
    static let stillleafBackup = UTType(filenameExtension: "sqlite", conformingTo: .database) ?? .database
}

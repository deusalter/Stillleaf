import SwiftUI
import BooksCore

/// TEMPORARY bisect switches; never merged.
enum PerfVariant {
    static var flags: Set<String> = []
    static func on(_ name: String) -> Bool { flags.contains(name) }
}

/// History's per-book chart colours. Everything else uses ReadingPalette directly.
enum AtlasStyle {
    static func book(_ id: String, dark: Bool) -> Color {
        let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let count = ThemeSnapshot.current().light.chart.count
        return ReadingPalette.chart(Int(hash % UInt64(max(1, count))))
    }
}

struct AtlasPanel<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var note: String = ""
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 10)
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(ReadingPalette.secondaryInk) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readingPanel()
    }
}

/// History actions share the dashboard's native disabled, focus, and glass
/// treatment instead of painting over those interaction states.
struct AtlasButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(ReadingButtonStyle())
            .controlSize(.small)
    }
}

@MainActor
struct AtlasLegend: View {
    let booksByID: [String: BookRecord]
    let bookIDs: [String]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(bookIDs, id: \.self) { id in
                HStack(spacing: 7) {
                    Circle().fill(AtlasStyle.book(id, dark: scheme == .dark)).frame(width: 8, height: 8)
                    let book = booksByID[id]
                    Text((book?.title ?? "Unknown book") + (book?.resolvedFormat == .audiobook ? " (audio)" : ""))
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
            }
        }
    }
}

@MainActor
struct AtlasBookLabel: View {
    let booksByID: [String: BookRecord]
    let id: String
    var detail: String = ""
    var small = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let book = booksByID[id]
        HStack(alignment: .center, spacing: 14) {
            BookCoverView(book: book, size: .compact)
            VStack(alignment: .leading, spacing: 5) {
                Text(book?.title ?? "Unknown book").font(.system(size: small ? 14 : 18, weight: .medium, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail.isEmpty ? (book?.author ?? "") : detail).font(.caption)
                    .foregroundStyle(ReadingPalette.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

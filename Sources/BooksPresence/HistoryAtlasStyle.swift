import SwiftUI
import BooksCore

/// History shares the dashboard's dynamic palette, including custom accents.
/// Keep the appearance parameter at call sites for the chart views' existing API;
/// ReadingPalette resolves the actual appearance through its dynamic colors.
enum AtlasStyle {
    static func canvas(_ dark: Bool) -> Color { ReadingPalette.canvas }
    static func surface(_ dark: Bool) -> Color { ReadingPalette.surface }
    static func ink(_ dark: Bool) -> Color { ReadingPalette.ink }
    static func muted(_ dark: Bool) -> Color { ReadingPalette.secondaryInk }
    static func rule(_ dark: Bool) -> Color { ReadingPalette.border }
    static func accent(_ dark: Bool) -> Color { ReadingPalette.accent }
    static func book(_ id: String, dark: Bool) -> Color {
        let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let count = ThemeSnapshot.current().light.chart.count
        return ReadingPalette.chart(Int(hash % UInt64(max(1, count))))
    }
    static func date(_ date: Date, zone: String, pattern: String) -> String {
        let formatter = DateFormatter(); formatter.locale = .current
        formatter.timeZone = TimeZone(identifier: zone) ?? .current; formatter.dateFormat = pattern
        return formatter.string(from: date)
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
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(AtlasStyle.muted(scheme == .dark)) }
            }
            content
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(AtlasStyle.surface(scheme == .dark), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct AtlasButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(AtlasStyle.surface(scheme == .dark).opacity(configuration.isPressed ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AtlasStyle.rule(scheme == .dark)))
    }
}

@MainActor
struct AtlasLegend: View {
    let model: AppModel
    let bookIDs: [String]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(bookIDs, id: \.self) { id in
                HStack(spacing: 7) {
                    Circle().fill(AtlasStyle.book(id, dark: scheme == .dark)).frame(width: 8, height: 8)
                    let book = model.books.first { $0.id == id }
                    Text((book?.title ?? "Unknown book") + (book?.resolvedFormat == .audiobook ? " (audio)" : ""))
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
            }
        }
    }
}

@MainActor
struct AtlasBookLabel: View {
    let model: AppModel
    let id: String
    var detail: String = ""
    var small = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let book = model.books.first { $0.id == id }
        HStack(alignment: .center, spacing: 14) {
            BookCoverView(book: book, size: .compact)
            VStack(alignment: .leading, spacing: 5) {
                Text(book?.title ?? "Unknown book").font(.system(size: small ? 14 : 18, weight: .medium, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail.isEmpty ? (book?.author ?? "") : detail).font(.caption)
                    .foregroundStyle(AtlasStyle.muted(scheme == .dark)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import SwiftUI
import BooksCore

/// Atlas owns its chart surfaces, not the dashboard theme or appearance preference.
enum AtlasStyle {
    static func canvas(_ dark: Bool) -> Color { color(dark ? 0x152630 : 0xF5F8FC) }
    static func surface(_ dark: Bool) -> Color { color(dark ? 0x1D323F : 0xFFFFFF) }
    static func ink(_ dark: Bool) -> Color { color(dark ? 0xEAF2FA : 0x183448) }
    static func muted(_ dark: Bool) -> Color { color(dark ? 0xA3B8C9 : 0x526C83) }
    static func rule(_ dark: Bool) -> Color { color(dark ? 0x354D5E : 0xDCE6EF) }
    static func accent(_ dark: Bool) -> Color { color(dark ? 0xA6BDF9 : 0x365BB8) }
    static func book(_ id: String, dark: Bool) -> Color {
        let colors: [UInt32] = dark ? [0x94B6FA, 0xC6A0E2, 0x79C8BE, 0xE1B38A, 0xAFADE9, 0xAEC482, 0xE8A4B4, 0x84C3DB] :
            [0x557CC6, 0xA16DBD, 0x3A918A, 0xB58159, 0x7775A8, 0x7C944C, 0xBC7487, 0x508CA7]
        let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return color(colors[Int(hash % UInt64(colors.count))])
    }
    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
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

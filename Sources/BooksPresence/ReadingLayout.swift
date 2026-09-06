import SwiftUI

/// Shared type scale: New York for display text and book titles, SF Pro for the rest.
enum ReadingType {
    static let pageTitle = Font.system(size: 34, weight: .regular, design: .serif)
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
    static func bookTitle(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .serif) }
    static func numeral(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
}

/// The page title block. It lives inside each screen's scroll view so it scrolls
/// away with the content instead of floating over it.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String?, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(ReadingType.pageTitle).tracking(-0.4)
                    .foregroundStyle(ReadingPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String?) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// Kept for sheets that still use the old name.
struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View { PageHeader(title, subtitle: subtitle) }
}

/// A labelled section with a plain sentence-case heading.
struct ReadingSection<Content: View, Accessory: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ReadingPalette.secondaryInk)
                        .accessibilityLabel(title).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    accessory
                }
                Hairline()
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ReadingSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// A 1px rule in the theme's border colour; vertical when `axis` is `.vertical`.
struct Hairline: View {
    var axis: Axis = .horizontal
    /// Captured at creation so a theme change gives the view new input and it redraws.
    var color: Color = ReadingPalette.border
    var body: some View {
        Rectangle().fill(color)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .accessibilityHidden(true)
    }
}

/// A quiet statistic: serif numeral over a small label, no card.
struct StatLine: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(ReadingType.numeral(26)).monospacedDigit()
                .foregroundStyle(ReadingPalette.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Same inset and readable width on every dashboard screen.
    func readingPage(maxWidth: CGFloat = 1000) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The one surface level: a soft card for a screen's primary block.
    func readingPanel() -> some View {
        padding(20)
            .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

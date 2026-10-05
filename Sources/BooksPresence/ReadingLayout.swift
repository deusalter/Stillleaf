import SwiftUI

/// SF for navigation and measurements; New York for book and editorial titles.
/// The walkthrough owns its display scale and does not use these page headings.
enum ReadingType {
    static let pageTitle = Font.system(size: 30, weight: .semibold)
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
    static let sectionTitle = Font.system(size: 14, weight: .semibold)
    static let controlLabel = Font.system(size: 12, weight: .medium)
    static func bookTitle(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .serif) }
    static func numeral(_ size: CGFloat) -> Font { .system(size: size, weight: .regular).monospacedDigit() }
}

/// Shared spacing, widths and corner radii. Screens draw from these so a surface
/// treatment can change in one place.
enum ReadingMetrics {
    /// Corner radii, smallest to largest.
    enum Radius {
        /// Chips, swatches and small badges.
        static let tight: CGFloat = 6
        /// Fields, menus and small tiles.
        static let control: CGFloat = 10
        /// Cards and panels.
        static let card: CGFloat = 16
        /// The menu panel and other floating surfaces.
        static let window: CGFloat = 20
    }

    /// Spacing steps for stacks and padding.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Horizontal inset of every dashboard screen.
    static let pageInset: CGFloat = 40
    /// Readable width for Today and Library.
    static let pageWidth: CGFloat = 1000
    /// Shorter measure for list screens: Timeline, Reviews, Health and Settings.
    static let listWidth: CGFloat = 860
    /// Inner padding of a card.
    static let cardPadding: CGFloat = 24
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

/// A labelled section with a plain sentence-case heading. With `glass`, the
/// heading and content sit together on one glass card, so no text is drawn
/// straight over the garden.
struct ReadingSection<Content: View, Accessory: View>: View {
    let title: String
    let glass: Bool
    let accessory: Accessory
    let content: Content

    init(_ title: String, glass: Bool = false, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.glass = glass
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        if glass {
            VStack(alignment: .leading, spacing: 16) {
                heading
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .readingPanel()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    heading
                    Hairline()
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(ReadingType.sectionTitle)
                .foregroundStyle(ReadingPalette.secondaryInk)
                .accessibilityLabel(title).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension ReadingSection where Accessory == EmptyView {
    init(_ title: String, glass: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title, glass: glass, accessory: { EmptyView() }, content: content)
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

/// A quiet statistic: stable-width digits over a small label, no card.
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
    func readingPage(maxWidth: CGFloat = ReadingMetrics.pageWidth) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, ReadingMetrics.pageInset).padding(.top, 34).padding(.bottom, ReadingMetrics.pageInset)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The one surface level: a glass card for a screen's primary block.
    func readingPanel() -> some View {
        padding(ReadingMetrics.cardPadding).glassSurface()
    }
}

struct ReadingEmptyState: View {
    let title: String
    let symbol: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(ReadingPalette.secondaryInk)
            Text(title).font(ReadingType.bookTitle(20))
            Text(message).font(.callout).foregroundStyle(ReadingPalette.secondaryInk).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

import SwiftUI

/// One setting: a title, an optional description under it, and the control on the
/// trailing edge. Every settings card is a stack of these, so labels, descriptions
/// and controls line up the same way on every page.
struct SettingsRow<Control: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: ReadingMetrics.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                if let description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }
        .padding(.vertical, ReadingMetrics.Space.m)
        .frame(minHeight: 48)
    }
}

/// The rule between two rows in a card.
struct SettingsDivider: View {
    var body: some View { Hairline() }
}

/// A line of dynamic status under a row, such as the Discord connection state.
struct SettingsStatus<Trailing: View>: View {
    let text: String
    let systemImage: String
    var warning = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
        }
        .font(.callout)
        .foregroundStyle(warning ? ReadingPalette.warning : ReadingPalette.secondaryInk)
        .padding(.bottom, ReadingMetrics.Space.m)
    }
}

extension SettingsStatus where Trailing == EmptyView {
    init(text: String, systemImage: String, warning: Bool = false) {
        self.init(text: text, systemImage: systemImage, warning: warning) { EmptyView() }
    }
}

/// A category change slides the new page a short way in the direction of travel
/// while it fades up. Nothing outgoing is kept, so there is no stacked layout and
/// no jump; Reduce Motion shows the page at once.
struct SettingsCategoryEntrance: ViewModifier {
    /// +1 when the new category is to the right of the old one, -1 when to the left, 0 for the first.
    let direction: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativePreviewReduceMotion) private var previewReduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        let still = previewReduceMotion ?? reduceMotion
        content
            .opacity(still || appeared ? 1 : 0)
            .offset(x: still || appeared ? 0 : direction * 16)
            .animation(still ? nil : ReadingMotion.entrance, value: appeared)
            .onAppear { appeared = true }
    }
}

import SwiftUI
import BooksCore

/// History's timescale menu and period stepper. Kept apart from `HistoryView`
/// so the smoke checks can host the controls on their own and drive them.
@MainActor
struct HistoryNavigationControls: View {
    @Binding var navigation: CalendarNavigation
    let canMoveForward: Bool

    var body: some View {
        ReadingGlassGroup {
            HStack(spacing: 7) {
                Menu {
                    Picker("Timescale", selection: Binding(get: { navigation.scale }, set: { navigation.setScale($0) })) {
                        ForEach(CalendarScale.allCases) { scale in Text(scale.title).tag(scale) }
                    }.pickerStyle(.inline)
                        // An inline picker's rows are toggles. The dashboard sets .switch for its
                        // settings, which menu rows can't render: every scale came up disabled.
                        .toggleStyle(.automatic)
                } label: {
                    Text(navigation.scale.title).font(.system(size: 12, weight: .medium))
                }.menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("History timescale").accessibilityValue(navigation.scale.title)
                    .help("Choose day, week, month, or year")
                Rectangle().fill(ReadingPalette.border).frame(width: 1, height: 16).padding(.horizontal, 4)
                    .accessibilityHidden(true)
                Button { navigation.move(by: -1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous \(navigation.scale.title.lowercased())")
                Button { if canMoveForward { navigation.move(by: 1) } } label: { Image(systemName: "chevron.right") }
                    .disabled(!canMoveForward).accessibilityLabel("Next \(navigation.scale.title.lowercased())")
                Button("Today") { navigation.goToToday() }
            }.buttonStyle(AtlasButtonStyle())
        }
    }
}

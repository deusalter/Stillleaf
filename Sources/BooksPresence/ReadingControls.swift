import SwiftUI

/// Selection motion is contained inside this control; the destination page is
/// never part of its animation transaction.
struct ReadingSegmentedControl<Value: Hashable>: View {
    let label: String
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var systemImage: ((Value) -> String)? = nil
    /// Keep the approved first-run tour's existing type and timing intact.
    var preservesWalkthroughTreatment = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Value?
    @Namespace private var highlight

    @ViewBuilder var body: some View {
        if preservesWalkthroughTreatment { walkthroughBody }
        else {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in Text(title(option)).tag(option) }
            }.pickerStyle(.segmented).accessibilityLabel(label)
        }
    }
    private var walkthroughBody: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    HStack(spacing: 7) {
                        if let systemImage {
                            Image(systemName: systemImage(option))
                                .accessibilityHidden(true)
                        }
                        Text(title(option))
                    }
                        .font(preservesWalkthroughTreatment
                              ? .system(size: 12, weight: selection == option ? .semibold : .medium)
                              : ReadingType.controlLabel)
                        .lineLimit(1).padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(selection == option ? ReadingPalette.ink : ReadingPalette.secondaryInk)
                        .background {
                            if selection == option {
                                // Flat selection surface; keyboard focus has its own outline.
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(colorScheme == .dark ? ReadingPalette.elevated : ReadingPalette.canvas)
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain).focused($focused, equals: option)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(focused == option ? ReadingPalette.accent : .clear, lineWidth: 2))
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(3)
        .background(ReadingPalette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(reduceMotion ? nil : (preservesWalkthroughTreatment ? .easeOut(duration: 0.16) : ReadingMotion.selection), value: selection)
        .accessibilityElement(children: .contain).accessibilityLabel(label)
        .onMoveCommand { direction in
            guard direction == .left || direction == .right,
                  let index = options.firstIndex(of: focused ?? selection), !options.isEmpty else { return }
            let next = min(options.count - 1, max(0, index + (direction == .right ? 1 : -1)))
            selection = options[next]; focused = selection
        }
    }
}

struct ReadingTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        ReadingFieldBody(field: configuration)
    }
}

private struct ReadingFieldBody<Label: View>: View {
    let field: TextField<Label>
    @FocusState private var focused: Bool
    var body: some View {
        field.textFieldStyle(.plain).focused($focused)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(ReadingPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(focused ? ReadingPalette.accent : ReadingPalette.border, lineWidth: focused ? 1.5 : 1))
    }
}

struct ReadingMenuPicker<Value: Hashable>: View {
    let label: String
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in Text(title(option)).tag(option) }
            }
        } label: {
            Text(title(selection)).lineLimit(1)
        }
        .menuStyle(ReadingMenuStyle())
        .accessibilityLabel(label).accessibilityValue(title(selection))
    }
}

struct ReadingSheetHeader: View {
    let title: String
    var subtitle: String? = nil
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(ReadingType.bookTitle(24))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                }
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(ReadingButtonStyle(iconOnly: true))
                .keyboardShortcut(.cancelAction).accessibilityLabel("Close")
        }
    }
}

struct ReadingSwitchRow: View {
    let title: String
    var symbol: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 12) {
            if let symbol { Label(title, systemImage: symbol) }
            else { Text(title) }
            Spacer(minLength: 4)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(title)
        }
    }
}

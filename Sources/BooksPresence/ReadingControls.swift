import SwiftUI

/// Selection motion is contained inside this control; the destination page is
/// never part of its animation transaction.
struct ReadingSegmentedControl<Value: Hashable>: View {
    let label: String
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var systemImage: ((Value) -> String)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Value?
    @Namespace private var highlight

    var body: some View {
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
                        .font(.system(size: 12, weight: selection == option ? .semibold : .medium))
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
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
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    if option == selection { Label(title(option), systemImage: "checkmark") }
                    else { Text(title(option)) }
                }
            }
        } label: {
            HStack {
                Text(title(selection)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.callout).foregroundStyle(ReadingPalette.ink)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(ReadingPalette.paper, in: RoundedRectangle(cornerRadius: 11))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .padding(10).background(ReadingPalette.paper, in: RoundedRectangle(cornerRadius: 11))
        .accessibilityLabel(label).accessibilityValue(title(selection))
    }
}

struct ReadingSheetHeader: View {
    let title: String
    let subtitle: String
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(ReadingType.bookTitle(24))
                Text(subtitle).font(.callout).foregroundStyle(ReadingPalette.fadedInk)
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

import SwiftUI

/// Keep native menu actions and selection semantics inside a compact reading toolbar surface.
struct ReadingMenuStyle: MenuStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .font(.caption.weight(.medium))
            .foregroundStyle(ReadingPalette.ink)
            .tint(ReadingPalette.ink)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 28)
            .background(ReadingPalette.accent.opacity(isHovering && isEnabled ? 0.14 : 0.075),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(ReadingPalette.accent.opacity(isFocused ? 1 : (isHovering && isEnabled ? 0.20 : 0.08)),
                            lineWidth: isFocused ? 2 : 1)
            }
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { isHovering = $0 }
    }
}

/// A compact native button treatment for reading actions. Button roles remain intact for VoiceOver,
/// keyboard activation, and destructive actions.
struct ReadingButtonStyle: ButtonStyle {
    enum Emphasis {
        case primary
        case secondary
    }

    let emphasis: Emphasis
    let iconOnly: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(emphasis: Emphasis = .secondary, iconOnly: Bool = false) {
        self.emphasis = emphasis
        self.iconOnly = iconOnly
    }

    func makeBody(configuration: Configuration) -> some View {
        ReadingButtonStyleBody(configuration: configuration, emphasis: emphasis, iconOnly: iconOnly, isEnabled: isEnabled, reduceMotion: reduceMotion)
    }
}

private struct ReadingButtonStyleBody: View {
    let configuration: ButtonStyleConfiguration
    let emphasis: ReadingButtonStyle.Emphasis
    let iconOnly: Bool
    let isEnabled: Bool
    let reduceMotion: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isFocused) private var isFocused
    @State private var isHovering = false

    var body: some View {
        let destructive = configuration.role == .destructive
        let primary = emphasis == .primary
        let accent = destructive ? ReadingPalette.warning : ReadingPalette.accent
        let foreground = primary ? ReadingPalette.onAccent : (destructive ? ReadingPalette.warning : ReadingPalette.ink)
        let hovering = isHovering && isEnabled
        let compact = controlSize == .small || controlSize == .mini
        let background = primary ? accent.opacity(hovering ? 0.90 : 1) : accent.opacity(destructive ? (hovering ? 0.15 : 0.08) : (hovering ? 0.14 : 0.075))

        configuration.label
            .font((compact ? Font.caption : Font.callout).weight(primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, iconOnly ? 9 : (compact ? 10 : 14))
            .padding(.vertical, compact ? 5 : 8)
            .frame(minWidth: iconOnly ? 32 : 0, minHeight: iconOnly ? 32 : (compact ? 28 : 36))
            .background(background, in: RoundedRectangle(cornerRadius: compact ? 9 : 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 9 : 13, style: .continuous)
                    .stroke(isFocused ? ReadingPalette.accent : (primary ? .clear : accent.opacity(destructive ? 0.25 : (hovering ? 0.20 : 0.08))), lineWidth: isFocused ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: compact ? 9 : 13, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.84 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : ReadingMotion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : ReadingMotion.hover, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

import SwiftUI

/// Keep native menu actions and selection semantics inside a compact reading toolbar surface.
struct ReadingMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .menuStyle(.button)
            .buttonStyle(ReadingButtonStyle())
            .controlSize(.small)
            .fixedSize()
    }
}

/// A compact native button treatment for reading actions. Button roles remain intact for VoiceOver,
/// keyboard activation, and destructive actions.
struct ReadingButtonStyle: PrimitiveButtonStyle {
    enum Emphasis {
        case primary
        case secondary
    }

    let emphasis: Emphasis
    let iconOnly: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque

    init(emphasis: Emphasis = .secondary, iconOnly: Bool = false) {
        self.emphasis = emphasis
        self.iconOnly = iconOnly
    }

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !(previewOpaque ?? reduceTransparency), contrast != .increased {
            if emphasis == .primary {
                Button(configuration)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(configuration.role == .destructive ? ReadingPalette.warning : ReadingPalette.accent)
            } else {
                Button(configuration)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .tint(.clear)
                    .foregroundStyle(configuration.role == .destructive ? ReadingPalette.warning : ReadingPalette.ink)
            }
        } else {
            fallback(configuration)
        }
        #else
        fallback(configuration)
        #endif
    }

    private func fallback(_ configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(ReadingFallbackButtonStyle(emphasis: emphasis, iconOnly: iconOnly))
    }
}

private struct ReadingFallbackButtonStyle: ButtonStyle {
    let emphasis: ReadingButtonStyle.Emphasis
    let iconOnly: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        ReadingButtonStyleBody(configuration: configuration, emphasis: emphasis, iconOnly: iconOnly,
                               isEnabled: isEnabled, reduceMotion: reduceMotion)
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
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    var body: some View {
        let destructive = configuration.role == .destructive
        let primary = emphasis == .primary
        let accent = destructive ? ReadingPalette.warning : ReadingPalette.accent
        let foreground = primary ? ReadingPalette.onAccent : (destructive ? ReadingPalette.warning : ReadingPalette.ink)
        let hovering = isHovering && isEnabled
        let compact = controlSize == .small || controlSize == .mini
        let background = primary ? accent.opacity(hovering ? 0.90 : 1) : ReadingPalette.elevated

        configuration.label
            .font((compact ? Font.caption : Font.callout).weight(primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, iconOnly ? 9 : (compact ? 10 : 14))
            .padding(.vertical, compact ? 5 : 8)
            .frame(minWidth: iconOnly ? 32 : 0, minHeight: iconOnly ? 32 : (compact ? 28 : 36))
            .background(background, in: RoundedRectangle(cornerRadius: compact ? 9 : 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 9 : 13, style: .continuous)
                    .stroke(isFocused ? ReadingPalette.accent : (primary ? .clear : accent.opacity(contrast == .increased ? 0.7 : (hovering ? 0.3 : 0.16))), lineWidth: isFocused ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: compact ? 9 : 13, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.84 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : ReadingMotion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : ReadingMotion.hover, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

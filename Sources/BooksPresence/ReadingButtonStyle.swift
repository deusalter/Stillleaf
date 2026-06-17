import SwiftUI

/// A compact native button treatment for reading actions. Button roles remain intact for VoiceOver,
/// keyboard activation, and destructive actions.
struct ReadingButtonStyle: ButtonStyle {
    enum Emphasis {
        case primary
        case secondary
    }

    let emphasis: Emphasis
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(emphasis: Emphasis = .secondary) {
        self.emphasis = emphasis
    }

    func makeBody(configuration: Configuration) -> some View {
        ReadingButtonStyleBody(configuration: configuration, emphasis: emphasis, isEnabled: isEnabled, reduceMotion: reduceMotion)
    }
}

private struct ReadingButtonStyleBody: View {
    let configuration: ButtonStyleConfiguration
    let emphasis: ReadingButtonStyle.Emphasis
    let isEnabled: Bool
    let reduceMotion: Bool
    @Environment(\.controlSize) private var controlSize
    @State private var isHovering = false

    var body: some View {
        let destructive = configuration.role == .destructive
        let primary = emphasis == .primary
        let accent = destructive ? Color.red : ReadingPalette.moss
        let foreground = primary ? ReadingPalette.paper : (destructive ? Color.red : ReadingPalette.ink)
        let hovering = isHovering && isEnabled
        let compact = controlSize == .small || controlSize == .mini
        let background = primary ? accent.opacity(hovering ? 0.90 : 1) : accent.opacity(destructive ? (hovering ? 0.15 : 0.08) : (hovering ? 0.13 : 0.055))

        configuration.label
            .font((compact ? Font.caption : Font.callout).weight(primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 8)
            .frame(minHeight: compact ? 26 : 34)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(primary ? accent.opacity(0.82) : accent.opacity(destructive ? 0.30 : (hovering ? 0.30 : 0.17)), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.84 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

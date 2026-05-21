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
    @State private var isHovering = false

    var body: some View {
        let destructive = configuration.role == .destructive
        let primary = emphasis == .primary
        let accent = destructive ? Color.red : ReadingPalette.moss
        let foreground = primary ? ReadingPalette.paper : (destructive ? Color.red : ReadingPalette.ink)
        let background = primary ? accent.opacity(isHovering ? 0.92 : 1) : accent.opacity(destructive ? (isHovering ? 0.17 : 0.11) : (isHovering ? 0.16 : 0.10))

        configuration.label
            .font(.callout.weight(primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(primary ? accent.opacity(0.82) : accent.opacity(destructive ? 0.5 : 0.42), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.84 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

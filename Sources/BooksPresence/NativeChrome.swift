import SwiftUI
import AppKit

private struct NativePreviewOpaque: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    var nativePreviewOpaque: Bool? { get { self[NativePreviewOpaque.self] } set { self[NativePreviewOpaque.self] = newValue } }
}

private struct NativePanelSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque
    @ViewBuilder func body(content: Content) -> some View {
        if (previewOpaque ?? opaque) || contrast == .increased {
            content.background(ReadingPalette.canvas, in: RoundedRectangle(cornerRadius: 20))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
            #else
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            #endif
        }
    }
}

extension View {
    func nativePanelSurface() -> some View { modifier(NativePanelSurface()) }
    func nativePopoverSurface() -> some View { modifier(NativePopoverSurface()) }
    func nativeMenuSurface(hovering: Bool) -> some View { modifier(NativeMenuSurface(hovering: hovering)) }
}

private struct NativeMenuSurface: ViewModifier {
    let hovering: Bool
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !(previewOpaque ?? opaque), contrast != .increased {
            content.glassEffect(.regular.tint(ReadingPalette.accent.opacity(hovering ? 0.12 : 0)), in: .capsule)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content.background(ReadingPalette.elevated, in: Capsule())
            .overlay(Capsule().stroke(ReadingPalette.accent.opacity(contrast == .increased ? 0.7 : (hovering ? 0.3 : 0.16))))
    }
}

/// A text-heavy menu needs the system popover material, not a refracting glass
/// sheet over desktop text. Glass belongs to the controls above this surface.
private struct NativePopoverSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque

    @ViewBuilder func body(content: Content) -> some View {
        if (previewOpaque ?? opaque) || contrast == .increased {
            content.background(ReadingPalette.canvas, in: RoundedRectangle(cornerRadius: 20))
        } else {
            content.background {
                PopoverMaterial().clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }
}

private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { }
}

/// Share sampling between adjacent controls without merging their shapes at rest.
struct ReadingGlassGroup<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    @ViewBuilder var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 4) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

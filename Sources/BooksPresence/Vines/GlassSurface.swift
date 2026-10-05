import SwiftUI

/// The one content surface over the garden: Liquid Glass on macOS 26, vibrancy
/// tinted with the theme surface before that, and the opaque surface colour
/// when Reduce Transparency or Increased Contrast is on.
private struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if (previewOpaque ?? reduceTransparency) || contrast == .increased {
            content.background(ReadingPalette.surface, in: shape)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(ReadingPalette.surface.opacity(0.55)), in: shape)
            } else {
                vibrant(content, shape)
            }
            #else
            vibrant(content, shape)
            #endif
        }
    }

    private func vibrant(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content.background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(ReadingPalette.surface.opacity(0.82))
            }
        }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = ReadingMetrics.Radius.card) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }
}

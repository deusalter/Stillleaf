import SwiftUI

private struct GardenBackdropKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when a garden draws behind this view and frosts it itself (see `GardenCanvas.frost`).
    var gardenBackdrop: Bool {
        get { self[GardenBackdropKey.self] }
        set { self[GardenBackdropKey.self] = newValue }
    }
}

private struct GlassOverDesktopKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True for glass that floats over the desktop (the menu bar panel) rather than
    /// over the app's own canvas: its cards are denser so text holds on any wallpaper.
    var glassOverDesktop: Bool {
        get { self[GlassOverDesktopKey.self] }
        set { self[GlassOverDesktopKey.self] = newValue }
    }
}

/// Glass panel frames in the garden's coordinate space, so the garden can draw a
/// softly blurred copy of itself behind each one.
struct GlassRegionsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}

/// The one content surface over the garden.
/// - Over a garden: the garden frosts the region itself with a light blur, and the
///   panel adds a tint, a specular rim, a top highlight and a soft shadow.
/// - Elsewhere: Liquid Glass on macOS 26, or a tinted material before that.
/// - Reduce Transparency or Increased Contrast: the opaque surface colour.
private struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque
    @Environment(\.gardenBackdrop) private var gardenBackdrop
    @Environment(\.glassOverDesktop) private var overDesktop
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if (previewOpaque ?? reduceTransparency) || contrast == .increased {
            content.background(ReadingPalette.surface, in: shape)
        } else if gardenBackdrop {
            frosted(content, shape)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: GlassRegionsKey.self, value: [proxy.frame(in: .named(GardenCanvas.space))])
                })
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(ReadingPalette.surface.opacity(0.55)), in: shape)
            } else {
                frosted(content.background(.ultraThinMaterial, in: shape), shape)
            }
            #else
            frosted(content.background(.ultraThinMaterial, in: shape), shape)
            #endif
        }
    }

    private func frosted<V: View>(_ content: V, _ shape: RoundedRectangle) -> some View {
        let dark = colorScheme == .dark
        return content
            .background {
                ZStack {
                    shape.fill(ReadingPalette.surface.opacity(overDesktop ? PanelGlass.cardTint(dark: dark) : GlassTint.cardFill(dark: dark)))
                    shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.08 : 0.34), .white.opacity(0)],
                                              startPoint: .topLeading, endPoint: UnitPoint(x: 0.55, y: 0.45)))
                }
                .shadow(color: .black.opacity(dark ? (overDesktop ? 0.24 : 0.38) : (overDesktop ? 0.08 : 0.12)),
                        radius: overDesktop ? 10 : 18, x: 0, y: overDesktop ? 4 : 10)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.22 : 0.9), .white.opacity(dark ? 0.04 : 0.3)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = ReadingMetrics.Radius.card) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }
}

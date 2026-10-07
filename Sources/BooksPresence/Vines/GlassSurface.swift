import SwiftUI

private struct GardenBackdropKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when a garden draws behind this view and frosts it itself (see `GardenCanvas.frost`).
    var gardenBackdrop: Bool {
        get { self[GardenBackdropKey.self] }
        set { self[GardenBackdropKey.self] = newValue }
    }
}

/// One glass panel as the garden needs it: its frame in the garden's coordinate
/// space and the corner radius of its (continuous) rounded rectangle.
struct GlassRegion: Equatable {
    var frame: CGRect
    var cornerRadius: CGFloat
}

/// Glass panels in the garden's coordinate space, so the garden can draw a
/// softly blurred copy of itself behind each one.
struct GlassRegionsKey: PreferenceKey {
    static let defaultValue: [GlassRegion] = []
    static func reduce(value: inout [GlassRegion], nextValue: () -> [GlassRegion]) { value.append(contentsOf: nextValue()) }
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
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if (previewOpaque ?? reduceTransparency) || contrast == .increased {
            content.background(ReadingPalette.surface, in: shape)
        } else if gardenBackdrop {
            frosted(content, shape)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: GlassRegionsKey.self, value: [GlassRegion(frame: proxy.frame(in: .named(GardenCanvas.space)), cornerRadius: cornerRadius)])
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
                    shape.fill(ReadingPalette.surface.opacity(dark ? 0.55 : 0.6))
                    shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.08 : 0.34), .white.opacity(0)],
                                              startPoint: .topLeading, endPoint: UnitPoint(x: 0.55, y: 0.45)))
                }
                .shadow(color: .black.opacity(dark ? 0.38 : 0.12), radius: 18, x: 0, y: 10)
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

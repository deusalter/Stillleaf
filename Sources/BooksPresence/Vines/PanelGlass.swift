import Foundation

/// How see-through the menu bar panel is. The panel floats over whatever is on
/// the desktop, so unlike the dashboard its glass cannot rely on a known canvas
/// behind it. The panel is one sheet of glass over its own garden: the theme
/// canvas over the desktop is the soil the vines grow on, the garden shows
/// through frosted, and a veil of the surface colour carries the text.
///
/// Kept free of SwiftUI so `scripts/theme-contrast-smoke.swift` can prove every
/// theme keeps text at WCAG AA over the worst desktops, in milliseconds.
enum PanelGlass {
    /// Share of the theme canvas laid over the desktop, under the garden. High
    /// enough that the vines, not the wallpaper, are what shows through the glass.
    static func shellTint(dark: Bool) -> Double { dark ? 0.88 : 0.92 }
    /// Share of the theme surface colour in the veil over the frosted garden,
    /// where the text sits. It fades out toward the panel's edge.
    static func veilTint(dark: Bool) -> Double { dark ? 0.62 : 0.74 }
    /// Strongest alpha of the white highlight along the panel's top edge.
    static func highlight(dark: Bool) -> Double { dark ? 0.05 : 0.22 }
    /// Allowance for the system's clear glass lifting what is behind it.
    static let glassLift = 0.08
    /// Mix of system blur (`NSVisualEffectView`) before macOS 26.
    static let blurMix = 0.35

    /// The colour under the text, over a flat desktop and the strongest frosted vine,
    /// with or without the top highlight (each is the worst case for some themes).
    static func veilColors(_ colors: ThemeColors, dark: Bool, desktop: UInt32, vine: UInt32) -> [UInt32] {
        var soil = ThemeContrast.blend(0xFFFFFF, over: desktop, alpha: glassLift)
        soil = ThemeContrast.blend(colors.canvas, over: soil, alpha: shellTint(dark: dark))
        return [soil, ThemeContrast.blend(0xFFFFFF, over: soil, alpha: highlight(dark: dark))].map { base in
            let frosted = ThemeContrast.blend(vine, over: base, alpha: GlassTint.frostCoverage)
            return ThemeContrast.blend(colors.surface, over: frosted, alpha: veilTint(dark: dark))
        }
    }

    /// Extremes and mid-tones of what a desktop might show behind the panel.
    static let probeDesktops: [UInt32] = [0x000000, 0xFFFFFF, 0x808080, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF, 0xFF00FF]
}

/// How much theme surface colour a glass card lays over the garden behind it.
/// Lower is clearer glass: more of the blurred vines show through.
enum GlassTint {
    static func cardFill(dark: Bool) -> Double { dark ? 0.48 : 0.55 }
    /// The most a blurred vine can colour the canvas behind a card. A glyph is a
    /// thin line, so blurring spreads it to well under half its strength.
    static let frostCoverage = 0.25
    /// The card colour where the strongest vine shows through: the frosted vine
    /// over the canvas, under the card's tint.
    static func worstCardColor(_ colors: ThemeColors, dark: Bool, vine: UInt32) -> UInt32 {
        let behind = ThemeContrast.blend(vine, over: colors.canvas, alpha: frostCoverage)
        return ThemeContrast.blend(colors.surface, over: behind, alpha: cardFill(dark: dark))
    }
}

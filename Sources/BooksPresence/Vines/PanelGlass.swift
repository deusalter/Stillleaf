import Foundation

/// How see-through the menu bar panel is. The panel floats over whatever is on the
/// desktop, so unlike the dashboard its glass cannot rely on a known canvas behind
/// it, and all of its text sits straight on the one surface. The surface is dense
/// enough for text to hold on any wallpaper; the desktop still shows through as a
/// soft tint, and the blur, rim and highlight keep it glass.
///
/// Kept free of SwiftUI so `scripts/theme-contrast-smoke.swift` can prove every
/// theme keeps text at WCAG AA over the worst desktops, in milliseconds.
enum PanelGlass {
    /// Share of the theme surface colour laid over the (blurred) desktop.
    static let surfaceTint = 0.93
    /// Strongest alpha of the white specular highlight along the panel's top edge.
    static func highlight(dark: Bool) -> Double { dark ? 0.05 : 0.08 }
    /// Allowance for the system's clear glass lifting what is behind it.
    static let glassLift = 0.08

    /// The colour of the panel where the highlight is strongest, over a flat desktop.
    static func surfaceColor(_ colors: ThemeColors, dark: Bool, desktop: UInt32) -> UInt32 {
        var color = ThemeContrast.blend(0xFFFFFF, over: desktop, alpha: glassLift)
        color = ThemeContrast.blend(colors.surface, over: color, alpha: surfaceTint)
        return ThemeContrast.blend(0xFFFFFF, over: color, alpha: highlight(dark: dark))
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

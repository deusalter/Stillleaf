import Foundation

/// How see-through the menu bar panel is. The panel floats over whatever is on
/// the desktop, so unlike the dashboard its glass cannot rely on a known canvas
/// behind it. Two layers share the job: a light shell tinted with the theme
/// canvas, and cards (surface colour) that carry all of the text.
///
/// Kept free of SwiftUI so `scripts/theme-contrast-smoke.swift` can prove every
/// theme keeps text at WCAG AA over the worst desktops, in milliseconds.
enum PanelGlass {
    /// Share of the theme canvas laid over the desktop. Low on purpose: the
    /// shell is clear glass, not frosted material.
    static func shellTint(dark: Bool) -> Double { dark ? 0.40 : 0.34 }
    /// Share of the theme surface colour on a card over the shell.
    static func cardTint(dark: Bool) -> Double { dark ? 0.92 : 0.80 }
    /// Strongest alpha of the white specular highlight on a card.
    static func cardHighlight(dark: Bool) -> Double { dark ? 0.08 : 0.34 }
    /// Allowance for the system's clear glass lifting what is behind it.
    static let glassLift = 0.08
    /// Mix of system blur (`NSVisualEffectView`) before macOS 26; kept low so
    /// the desktop stays recognisable.
    static let blurMix = 0.35

    /// The colour of a card where the highlight is strongest, over a flat desktop.
    static func cardColor(_ colors: ThemeColors, dark: Bool, desktop: UInt32) -> UInt32 {
        var color = ThemeContrast.blend(0xFFFFFF, over: desktop, alpha: glassLift)
        color = ThemeContrast.blend(colors.canvas, over: color, alpha: shellTint(dark: dark))
        color = ThemeContrast.blend(colors.surface, over: color, alpha: cardTint(dark: dark))
        return ThemeContrast.blend(0xFFFFFF, over: color, alpha: cardHighlight(dark: dark))
    }

    /// Extremes and mid-tones of what a desktop might show behind the panel.
    static let probeDesktops: [UInt32] = [0x000000, 0xFFFFFF, 0x808080, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF, 0xFF00FF]
}

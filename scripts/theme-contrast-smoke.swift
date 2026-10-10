import Foundation

/// Compiled together with Theme.swift, VineField.swift, VinePalette.swift and PanelGlass.swift only, so every
/// palette can be checked in milliseconds without launching the app.
@main
struct ThemeContrastSmoke {
    static func main() {
        guard ReadingTheme.all.count >= 6, ReadingTheme.named("bogus").id == "stillleaf",
              ReadingTheme.named(nil).id == "stillleaf", AccentPreset.named("bogus") == nil else {
            print("theme-contrast-smoke: catalogue or fallback failed"); exit(1)
        }
        guard Set(ReadingTheme.all.map(\.id)).count == ReadingTheme.all.count,
              Set(AccentPreset.all.map(\.id)).count == AccentPreset.all.count else {
            print("theme-contrast-smoke: duplicate theme or accent id"); exit(1)
        }
        guard abs(ThemeContrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.01,
              abs(ThemeContrast.ratio(0x777777, 0xFFFFFF) - 4.48) < 0.01 else {
            print("theme-contrast-smoke: WCAG ratio maths wrong"); exit(1)
        }
        let rose = AccentPreset.named("rose")!
        let tinted = ReadingTheme.named("ocean").colors(dark: true, accent: rose)
        guard tinted.accent == rose.dark, tinted.onAccent == rose.onDark,
              tinted.canvas == ReadingTheme.named("ocean").dark.canvas else {
            print("theme-contrast-smoke: accent override did not replace only the accent"); exit(1)
        }
        let failures = ThemeContrast.failures()
        failures.forEach { print("theme-contrast-smoke: FAIL \($0)") }
        guard failures.isEmpty else { exit(1) }
        // Vine glyphs are decorative graphics on the canvas: 3:1 in every theme, appearance and accent.
        var vineChecks = 0
        for theme in ReadingTheme.all {
            for dark in [false, true] {
                for accent in [nil] + AccentPreset.all.map(Optional.some) {
                    let colors = theme.colors(dark: dark, accent: accent)
                    let palette = VinePalette.make(colors, dark: dark)
                    for hex in palette.stems + palette.leaves + palette.blooms {
                        vineChecks += 1
                        let ratio = ThemeContrast.ratio(hex, colors.canvas)
                        guard ratio >= 3 else {
                            print("theme-contrast-smoke: FAIL \(theme.id)/\(dark ? "dark" : "light")/\(accent?.id ?? "default") vine \(String(hex, radix: 16)) is \(String(format: "%.2f", ratio)):1 on canvas")
                            exit(1)
                        }
                    }
                    guard palette.color(.leaf, slot: 7) == palette.leaves[7 % palette.leaves.count],
                          palette.color(.bloom, slot: 0) == palette.blooms[0] else {
                        print("theme-contrast-smoke: vine palette slots do not wrap"); exit(1)
                    }
                }
            }
        }
        // The menu panel floats over any desktop: text on its veil must hold at AA on the worst ones, over the strongest frosted vine.
        var panelChecks = 0, panelFailures: [String] = []
        for theme in ReadingTheme.all {
            for dark in [false, true] {
                for accent in [nil] + AccentPreset.all.map(Optional.some) {
                    let colors = theme.colors(dark: dark, accent: accent)
                    let palette = VinePalette.make(colors, dark: dark)
                    for desktop in PanelGlass.probeDesktops {
                        for vine in palette.stems + palette.leaves + palette.blooms {
                            for veil in PanelGlass.veilColors(colors, dark: dark, desktop: desktop, vine: vine) {
                                for (name, hex, floor) in [("ink", colors.ink, 4.5), ("secondary ink", colors.secondaryInk, 4.5), ("accent", colors.accent, 3)] {
                                    panelChecks += 1
                                    let ratio = ThemeContrast.ratio(hex, veil)
                                    if ratio < floor {
                                        panelFailures.append("\(theme.id)/\(dark ? "dark" : "light")/\(accent?.id ?? "default") \(name) is \(String(format: "%.2f", ratio)):1 on the menu panel veil over desktop \(String(desktop, radix: 16)) and vine \(String(vine, radix: 16))")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        panelFailures.prefix(12).forEach { print("theme-contrast-smoke: FAIL \($0)") }
        guard panelFailures.isEmpty else { print("theme-contrast-smoke: \(panelFailures.count) of \(panelChecks) menu panel checks fail"); exit(1) }
        // Dashboard cards show the blurred garden through; text must hold even over the strongest vine colour.
        var cardChecks = 0, cardFailures: [String] = []
        for theme in ReadingTheme.all {
            for dark in [false, true] {
                let colors = theme.colors(dark: dark, accent: nil)
                let palette = VinePalette.make(colors, dark: dark)
                for vine in palette.stems + palette.leaves + palette.blooms {
                    let card = GlassTint.worstCardColor(colors, dark: dark, vine: vine)
                    for (name, hex) in [("ink", colors.ink), ("secondary ink", colors.secondaryInk)] {
                        cardChecks += 1
                        let ratio = ThemeContrast.ratio(hex, card)
                        if ratio < 4.5 { cardFailures.append("\(theme.id)/\(dark ? "dark" : "light") \(name) is \(String(format: "%.2f", ratio)):1 on a card over vine \(String(vine, radix: 16))") }
                    }
                }
            }
        }
        cardFailures.prefix(8).forEach { print("theme-contrast-smoke: FAIL \($0)") }
        guard cardFailures.isEmpty else { print("theme-contrast-smoke: \(cardFailures.count) of \(cardChecks) glass card checks fail"); exit(1) }
        print("theme-contrast-smoke: \(cardChecks) glass card text checks pass over the strongest vine colours")
        guard PanelGlass.veilTint(dark: false) <= 0.75, PanelGlass.veilTint(dark: true) <= 0.75 else {
            print("theme-contrast-smoke: the menu panel veil is too dense for the garden to show through"); exit(1)
        }
        print("theme-contrast-smoke: \(panelChecks) menu panel text checks pass over \(PanelGlass.probeDesktops.count) desktops and every frosted vine colour")
        print("theme-contrast-smoke: \(ReadingTheme.all.count) themes × 2 appearances × \(AccentPreset.all.count + 1) accents pass WCAG AA; \(vineChecks) vine colours pass 3:1")
    }
}

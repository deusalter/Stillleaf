import Foundation

/// One appearance of a theme, as sRGB hex values. Foundation only, so the
/// contrast smoke can compile this file on its own.
struct ThemeColors: Equatable {
    var canvas: UInt32
    var surface: UInt32
    var elevated: UInt32
    var ink: UInt32
    var secondaryInk: UInt32
    var accent: UInt32
    var onAccent: UInt32
    var border: UInt32
    var track: UInt32
    var warning: UInt32
    /// Goal met, pages read, time only.
    var chart: [UInt32]
}

struct ReadingTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let light: ThemeColors
    let dark: ThemeColors

    func colors(dark isDark: Bool, accent: AccentPreset?) -> ThemeColors {
        var colors = isDark ? dark : light
        if let accent {
            colors.accent = isDark ? accent.dark : accent.light
            colors.onAccent = isDark ? accent.onDark : accent.onLight
            colors.chart[0] = colors.accent
        }
        return colors
    }

    static func named(_ id: String?) -> ReadingTheme {
        all.first { $0.id == id } ?? all[0]
    }

    static let all: [ReadingTheme] = [
        ReadingTheme(id: "stillleaf", name: "Stillleaf",
            light: ThemeColors(canvas: 0xF5F8F5, surface: 0xE9F1ED, elevated: 0xDCE9E2, ink: 0x183D33, secondaryInk: 0x4B6A5E,
                               accent: 0x176650, onAccent: 0xFFFFFF, border: 0xD0DED6, track: 0xD5E4DC, warning: 0x8A5A1F,
                               chart: [0x176650, 0x9A6424, 0x6E877C]),
            dark: ThemeColors(canvas: 0x111A18, surface: 0x18251F, elevated: 0x22332D, ink: 0xE6F1EB, secondaryInk: 0xA3BAAF,
                              accent: 0x6FD4AE, onAccent: 0x0E2E23, border: 0x2A3B35, track: 0x24352F, warning: 0xE2B574,
                              chart: [0x6FD4AE, 0xE2B574, 0x7F978C])),
        ReadingTheme(id: "graphite", name: "Graphite",
            light: ThemeColors(canvas: 0xF6F6F7, surface: 0xECECEE, elevated: 0xE1E1E4, ink: 0x1D1D1F, secondaryInk: 0x5A5A61,
                               accent: 0x2A5BD7, onAccent: 0xFFFFFF, border: 0xD6D6DB, track: 0xDDDDE2, warning: 0x8F5500,
                               chart: [0x2A5BD7, 0xA15F14, 0x7C7C85]),
            dark: ThemeColors(canvas: 0x151516, surface: 0x1F1F21, elevated: 0x2A2A2D, ink: 0xECECEF, secondaryInk: 0xA6A6AD,
                              accent: 0x86ABFF, onAccent: 0x0B1A3D, border: 0x333337, track: 0x2D2D31, warning: 0xE6B25E,
                              chart: [0x86ABFF, 0xE0A15A, 0x85858E])),
        ReadingTheme(id: "ocean", name: "Ocean",
            light: ThemeColors(canvas: 0xF3F7FA, surface: 0xE7EFF5, elevated: 0xD9E6EF, ink: 0x14324A, secondaryInk: 0x46607A,
                               accent: 0x0B67A3, onAccent: 0xFFFFFF, border: 0xCBDBE6, track: 0xD3E2EC, warning: 0x8A560F,
                               chart: [0x0B67A3, 0xA3601C, 0x6D8599]),
            dark: ThemeColors(canvas: 0x0F1822, surface: 0x16222E, elevated: 0x20303F, ink: 0xE3EEF6, secondaryInk: 0x9FB5C6,
                              accent: 0x6CC0F0, onAccent: 0x06263A, border: 0x27394B, track: 0x223242, warning: 0xE7B46C,
                              chart: [0x6CC0F0, 0xE3A35E, 0x7C94A8])),
        ReadingTheme(id: "clay", name: "Clay",
            light: ThemeColors(canvas: 0xF9F5F0, surface: 0xF1E9E0, elevated: 0xE7DBCE, ink: 0x3A2618, secondaryInk: 0x6A5243,
                               accent: 0xA4492D, onAccent: 0xFFFFFF, border: 0xDFD0C0, track: 0xE6D8CA, warning: 0x80580C,
                               chart: [0xA4492D, 0x2F7466, 0x94806F]),
            dark: ThemeColors(canvas: 0x1B1511, surface: 0x251D18, elevated: 0x322720, ink: 0xF2E7DC, secondaryInk: 0xC2AD9C,
                              accent: 0xF08A68, onAccent: 0x3A1206, border: 0x3B2F27, track: 0x352A21, warning: 0xE8B86A,
                              chart: [0xF08A68, 0x7FC4AE, 0x9A897B])),
        ReadingTheme(id: "plum", name: "Plum",
            light: ThemeColors(canvas: 0xF8F5F9, surface: 0xEFE8F2, elevated: 0xE4D9E9, ink: 0x32203D, secondaryInk: 0x62506D,
                               accent: 0x7A3E9F, onAccent: 0xFFFFFF, border: 0xDBCEE1, track: 0xE2D6E8, warning: 0x86560F,
                               chart: [0x7A3E9F, 0xA35E1D, 0x8C7D96]),
            dark: ThemeColors(canvas: 0x18131C, surface: 0x211A27, elevated: 0x2D2334, ink: 0xEFE6F4, secondaryInk: 0xB9A8C4,
                              accent: 0xC9A0F0, onAccent: 0x2B1240, border: 0x362B3E, track: 0x302638, warning: 0xE6B46A,
                              chart: [0xC9A0F0, 0xE4A25E, 0x8E7F99])),
        ReadingTheme(id: "forest", name: "Forest",
            light: ThemeColors(canvas: 0xF4F6F1, surface: 0xE8EDE2, elevated: 0xDBE3D2, ink: 0x1F2E1C, secondaryInk: 0x4D5D48,
                               accent: 0x2F6B2A, onAccent: 0xFFFFFF, border: 0xCCD6C3, track: 0xD5DECC, warning: 0x7A560F,
                               chart: [0x2F6B2A, 0x92641A, 0x72826C]),
            dark: ThemeColors(canvas: 0x111610, surface: 0x192017, elevated: 0x232C20, ink: 0xE5EDDF, secondaryInk: 0xA8B7A0,
                              accent: 0x9CCB7A, onAccent: 0x17280C, border: 0x2B3527, track: 0x263022, warning: 0xD9B45E,
                              chart: [0x9CCB7A, 0xD9A95E, 0x84927D]))
    ]
}

/// An accent-only override. Each tone is pre-checked against every theme.
struct AccentPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let light: UInt32
    let dark: UInt32
    let onLight: UInt32
    let onDark: UInt32

    static func named(_ id: String?) -> AccentPreset? {
        all.first { $0.id == id }
    }

    static let all: [AccentPreset] = [
        AccentPreset(id: "leaf", name: "Leaf", light: 0x176650, dark: 0x6FD4AE, onLight: 0xFFFFFF, onDark: 0x0E2E23),
        AccentPreset(id: "teal", name: "Teal", light: 0x0D6B70, dark: 0x5FCFD5, onLight: 0xFFFFFF, onDark: 0x08312F),
        AccentPreset(id: "blue", name: "Blue", light: 0x1F5CC4, dark: 0x8AB0FF, onLight: 0xFFFFFF, onDark: 0x0B1A3D),
        AccentPreset(id: "indigo", name: "Indigo", light: 0x4A48B8, dark: 0xA9AAFF, onLight: 0xFFFFFF, onDark: 0x1A1A4A),
        AccentPreset(id: "violet", name: "Violet", light: 0x7A3E9F, dark: 0xCBA3F2, onLight: 0xFFFFFF, onDark: 0x2B1240),
        AccentPreset(id: "rose", name: "Rose", light: 0xAD2F58, dark: 0xF59AB4, onLight: 0xFFFFFF, onDark: 0x4A0F22),
        AccentPreset(id: "terracotta", name: "Terracotta", light: 0xA4492D, dark: 0xF08A68, onLight: 0xFFFFFF, onDark: 0x3A1206),
        AccentPreset(id: "amber", name: "Amber", light: 0x845600, dark: 0xE8B45A, onLight: 0xFFFFFF, onDark: 0x3A2600)
    ]
}

/// WCAG 2.x relative luminance and contrast ratio.
enum ThemeContrast {
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Text pairs need 4.5:1; accent and chart marks are UI graphics and need 3:1.
    static func failures() -> [String] {
        var failures: [String] = []
        for theme in ReadingTheme.all {
            for dark in [false, true] {
                for accent in [nil] + AccentPreset.all.map(Optional.some) {
                    let c = theme.colors(dark: dark, accent: accent)
                    let label = "\(theme.id)/\(dark ? "dark" : "light")/\(accent?.id ?? "default")"
                    var checks: [(String, UInt32, UInt32, Double)] = [
                        ("onAccent on accent", c.onAccent, c.accent, 4.5),
                        ("accent on canvas", c.accent, c.canvas, 3),
                        ("accent on surface", c.accent, c.surface, 3)
                    ]
                    if accent == nil {
                        checks += [
                            ("ink on canvas", c.ink, c.canvas, 4.5), ("ink on surface", c.ink, c.surface, 4.5),
                            ("secondary on canvas", c.secondaryInk, c.canvas, 4.5),
                            ("secondary on surface", c.secondaryInk, c.surface, 4.5),
                            ("warning on canvas", c.warning, c.canvas, 4.5)
                        ]
                        checks += c.chart.enumerated().map { ("chart \($0.offset) on surface", $0.element, c.surface, 3) }
                    }
                    for (name, fg, bg, minimum) in checks where ratio(fg, bg) < minimum {
                        failures.append("\(label): \(name) \(String(format: "%.2f", ratio(fg, bg))) < \(minimum)")
                    }
                }
            }
        }
        return failures
    }
}

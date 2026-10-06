import Foundation

/// Vine colours derived from a theme: stems and leaves fan out around the
/// accent hue, blooms use the theme's warm chart colour and two complements.
/// Every colour is nudged until it reaches 3:1 on the canvas.
struct VinePalette: Equatable {
    let stems: [UInt32]
    let leaves: [UInt32]
    let blooms: [UInt32]
    /// The gliding dot at a growing tip.
    let head: UInt32
    let pollen: UInt32
    let pollenAlpha: Double
    /// Dotted tracks and other faint marks; drawn with reduced alpha.
    let track: UInt32
    let baseAlpha: Double

    static func make(_ colors: ThemeColors, dark: Bool) -> VinePalette {
        let (hue, saturation, _) = hsl(colors.accent)
        let s = min(0.8, max(0.38, saturation))
        let leafLightness = dark ? [0.64, 0.71, 0.57, 0.75, 0.67] : [0.36, 0.42, 0.32, 0.29, 0.40]
        let leaves = zip([0.0, 16, -14, 30, -28], leafLightness).map { fromHSL(hue + $0, s, $1) }
        let stems = [colors.accent, mix(colors.accent, colors.ink, 0.25), mix(colors.accent, colors.chart[2], 0.35),
                     fromHSL(hue, s * 0.9, dark ? 0.46 : 0.26)]
        let blooms = [colors.chart[1], dark ? 0xF5C65E : 0xD48E14,
                      fromHSL(hue + 150, 0.62, dark ? 0.72 : 0.52), fromHSL(hue + 205, 0.55, dark ? 0.74 : 0.50)]
        let legible = { (hex: UInt32) in contrasting(hex, on: colors.canvas, dark: dark) }
        return VinePalette(stems: stems.map(legible), leaves: leaves.map(legible), blooms: blooms.map(legible),
                           head: dark ? mix(colors.accent, 0xFFFFFF, 0.7) : mix(colors.accent, 0x000000, 0.35),
                           pollen: colors.accent, pollenAlpha: dark ? 0.19 : 0.24, track: colors.ink, baseAlpha: dark ? 0.85 : 0.96)
    }

    func color(_ kind: VineKind, slot: Int) -> UInt32 {
        let colors: [UInt32]
        switch kind {
        case .stem: colors = stems
        case .leaf: colors = leaves
        case .bloom: colors = blooms
        }
        return colors[((slot % colors.count) + colors.count) % colors.count]
    }

    // MARK: Colour maths

    private static func contrasting(_ hex: UInt32, on canvas: UInt32, dark: Bool) -> UInt32 {
        var (h, s, l) = hsl(hex)
        var color = hex
        for _ in 0..<12 where ThemeContrast.ratio(color, canvas) < 3 {
            l = min(1, max(0, l + (dark ? 0.03 : -0.03)))
            color = fromHSL(h, s, l)
        }
        return color
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let x = channels(a), y = channels(b)
        return pack(zip(x, y).map { $0 + ($1 - $0) * t })
    }

    private static func channels(_ hex: UInt32) -> [Double] {
        [Double((hex >> 16) & 0xff), Double((hex >> 8) & 0xff), Double(hex & 0xff)]
    }

    private static func pack(_ rgb: [Double]) -> UInt32 {
        let c = rgb.map { UInt32(max(0, min(255, $0.rounded()))) }
        return c[0] << 16 | c[1] << 8 | c[2]
    }

    static func hsl(_ hex: UInt32) -> (Double, Double, Double) {
        let rgb = channels(hex).map { $0 / 255 }
        let high = rgb.max()!, low = rgb.min()!, l = (high + low) / 2
        guard high != low else { return (0, 0, l) }
        let d = high - low, s = l > 0.5 ? d / (2 - high - low) : d / (high + low)
        let h: Double
        if high == rgb[0] { h = (rgb[1] - rgb[2]) / d + (rgb[1] < rgb[2] ? 6 : 0) }
        else if high == rgb[1] { h = (rgb[2] - rgb[0]) / d + 2 }
        else { h = (rgb[0] - rgb[1]) / d + 4 }
        return (h * 60, s, l)
    }

    static func fromHSL(_ hue: Double, _ saturation: Double, _ lightness: Double) -> UInt32 {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let s = min(1, max(0, saturation)), l = min(1, max(0, lightness))
        let c = (1 - abs(2 * l - 1)) * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let rgb: (Double, Double, Double)
        switch h {
        case ..<60: rgb = (c, x, 0)
        case ..<120: rgb = (x, c, 0)
        case ..<180: rgb = (0, c, x)
        case ..<240: rgb = (0, x, c)
        case ..<300: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return pack([(rgb.0 + m) * 255, (rgb.1 + m) * 255, (rgb.2 + m) * 255])
    }
}

import AppKit
import SwiftUI

/// The selected theme, persisted in UserDefaults. Views that host whole screens
/// observe `revision` and re-key render-only subtrees so colours re-resolve;
/// views that own draft state are never re-keyed.
@MainActor
final class ThemeStore: ObservableObject {
    static let themeKey = "appearanceTheme"
    static let accentKey = "appearanceAccent"
    static let shared = ThemeStore(defaults: .standard)

    @Published private(set) var revision = 0
    private(set) var themeID = ReadingTheme.all[0].id
    private(set) var accentID: String?
    private var defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        load()
    }

    var theme: ReadingTheme { ReadingTheme.named(themeID) }
    var accent: AccentPreset? { AccentPreset.named(accentID) }

    func select(theme id: String) {
        guard ReadingTheme.all.contains(where: { $0.id == id }), id != themeID else { return }
        themeID = id
        defaults.set(id, forKey: Self.themeKey)
        publish()
    }

    /// `nil` restores the theme's own accent.
    func select(accent id: String?) {
        let valid = id.flatMap { AccentPreset.named($0)?.id }
        guard valid != accentID else { return }
        accentID = valid
        if let valid { defaults.set(valid, forKey: Self.accentKey) } else { defaults.removeObject(forKey: Self.accentKey) }
        publish()
    }

    /// Points the store at another defaults suite (previews and self-tests) and re-reads the choice.
    func reload(from defaults: UserDefaults) {
        self.defaults = defaults
        load()
    }

    private func load() {
        themeID = ReadingTheme.named(defaults.string(forKey: Self.themeKey)).id
        accentID = AccentPreset.named(defaults.string(forKey: Self.accentKey))?.id
        publish()
    }

    private func publish() {
        ThemeSnapshot.update(light: theme.colors(dark: false, accent: accent), dark: theme.colors(dark: true, accent: accent))
        revision += 1
    }
}

/// Thread-safe copy of the resolved colours. Dynamic NSColor providers can run
/// during drawing off the main actor, so they read this rather than the store.
enum ThemeSnapshot {
    struct State { var revision: Int; var light: ThemeColors; var dark: ThemeColors }
    private static let lock = NSLock()
    private static var state = State(revision: 0, light: ReadingTheme.all[0].light, dark: ReadingTheme.all[0].dark)

    static func current() -> State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    static func update(light: ThemeColors, dark: ThemeColors) {
        lock.lock(); defer { lock.unlock() }
        state = State(revision: state.revision + 1, light: light, dark: dark)
    }
}

/// Theme tokens. Each token is a dynamic colour that resolves light or dark per
/// appearance from the current theme. A new `Color` instance is made per theme
/// revision so re-rendered views never compare equal to the previous theme.
enum ReadingPalette {
    private static let lock = NSLock()
    private static var cache: (revision: Int, colors: [String: Color]) = (-1, [:])

    private static func token(_ key: String, _ pick: @escaping (ThemeColors) -> UInt32) -> Color {
        let revision = ThemeSnapshot.current().revision
        lock.lock(); defer { lock.unlock() }
        if cache.revision != revision { cache = (revision, [:]) }
        if let color = cache.colors[key] { return color }
        let color = Color(NSColor(name: nil) { appearance in
            let snapshot = ThemeSnapshot.current()
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(pick(dark ? snapshot.dark : snapshot.light))
        })
        cache.colors[key] = color
        return color
    }

    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                blue: Double(hex & 0xff) / 255, alpha: 1)
    }

    /// A fixed colour, for swatches that preview a theme other than the current one.
    static func fixed(_ hex: UInt32) -> Color { Color(nsColor(hex)) }

    static var canvas: Color { token("canvas") { $0.canvas } }
    static var surface: Color { token("surface") { $0.surface } }
    static var elevated: Color { token("elevated") { $0.elevated } }
    static var ink: Color { token("ink") { $0.ink } }
    static var secondaryInk: Color { token("secondaryInk") { $0.secondaryInk } }
    static var accent: Color { token("accent") { $0.accent } }
    static var onAccent: Color { token("onAccent") { $0.onAccent } }
    static var border: Color { token("border") { $0.border } }
    static var track: Color { token("track") { $0.track } }
    static var warning: Color { token("warning") { $0.warning } }
    static func chart(_ index: Int) -> Color { token("chart\(index)") { $0.chart[min(max(index, 0), $0.chart.count - 1)] } }

    // Stars are gold in every theme, so they only vary by appearance.
    static let star = appearanceColor(light: StarColors.fillLight, dark: StarColors.fillDark)
    static let starEdge = appearanceColor(light: StarColors.edgeLight, dark: StarColors.edgeDark)

    private static func appearanceColor(light: UInt32, dark: UInt32) -> Color {
        Color(NSColor(name: nil) { appearance in
            nsColor(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }

    // Legacy names used across the dashboard; they alias the tokens above.
    static var paper: Color { canvas }
    static var sidebar: Color { canvas }
    static var parchment: Color { elevated }
    static var fadedInk: Color { secondaryInk }
    static var moss: Color { accent }
    static var accentEnd: Color { accent }
    static var ochre: Color { warning }
    static var progressTrack: Color { track }
}

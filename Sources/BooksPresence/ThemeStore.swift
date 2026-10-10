import AppKit
import SwiftUI

enum DashboardAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// How the ASCII garden behaves. Reduce Motion and Low Power turn Animated into Still.
enum GardenMode: String, CaseIterable, Identifiable {
    case animated, still, off
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Where Low Power Mode is read from and announced. Self-checks inject their own.
struct LowPowerSource {
    var isEnabled: () -> Bool
    var center: NotificationCenter

    static let system = LowPowerSource(isEnabled: { ProcessInfo.processInfo.isLowPowerModeEnabled }, center: .default)
}

/// The selected theme, persisted in UserDefaults. Views that host whole screens
/// observe `revision` and re-key render-only subtrees so colours re-resolve;
/// views that own draft state are never re-keyed.
@MainActor
final class ThemeStore: ObservableObject {
    static let themeKey = "appearanceTheme"
    static let accentKey = "appearanceAccent"
    static let modeKey = "appearanceMode"
    static let gardenKey = "gardenMode"
    static let shared = ThemeStore(defaults: .standard)

    @Published private(set) var revision = 0
    private(set) var themeID = ReadingTheme.all[0].id
    private(set) var accentID: String?
    private(set) var appearanceMode: DashboardAppearance = .system
    private(set) var gardenMode: GardenMode = .animated
    private var defaults: UserDefaults
    private let lowPower: LowPowerSource
    private var lowPowerEnabled: Bool
    private var lowPowerObserver: NSObjectProtocol?

    init(defaults: UserDefaults, lowPower: LowPowerSource = .system) {
        self.defaults = defaults
        self.lowPower = lowPower
        lowPowerEnabled = lowPower.isEnabled()
        load()
        // The system posts this from any thread; hop to the main actor only when needed.
        lowPowerObserver = lowPower.center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            guard let store = self else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { store.lowPowerChanged() }
            } else {
                DispatchQueue.main.async { store.lowPowerChanged() }
            }
        }
    }

    deinit {
        if let lowPowerObserver { lowPower.center.removeObserver(lowPowerObserver) }
    }

    /// Gardens switch to Still the moment Low Power Mode starts and animate again when it ends.
    /// `revision` is what the reader window watches, so it moves too, but only when the
    /// change is visible: a garden set to Still or Off looks the same either way.
    private func lowPowerChanged() {
        let enabled = lowPower.isEnabled()
        guard enabled != lowPowerEnabled else { return }
        lowPowerEnabled = enabled
        if gardenMode == .animated { revision += 1 }
    }

    /// Whether Low Power Mode is on, as of the last change the store was told about.
    var lowPowerIsOn: Bool { lowPowerEnabled }

    var theme: ReadingTheme { ReadingTheme.named(themeID) }
    var accent: AccentPreset? { AccentPreset.named(accentID) }

    func select(appearance mode: DashboardAppearance) {
        guard mode != appearanceMode else { return }
        appearanceMode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        NSApp?.appearance = mode.nativeAppearance
        publish()
    }

    func select(theme id: String) {
        guard ReadingTheme.all.contains(where: { $0.id == id }), id != themeID else { return }
        themeID = id
        defaults.set(id, forKey: Self.themeKey)
        publish()
    }

    func select(garden mode: GardenMode) {
        guard mode != gardenMode else { return }
        gardenMode = mode
        defaults.set(mode.rawValue, forKey: Self.gardenKey)
        publish()
    }

    /// The mode to render: Animated becomes Still under Reduce Motion or Low Power Mode.
    func effectiveGardenMode(reduceMotion: Bool) -> GardenMode {
        guard gardenMode == .animated else { return gardenMode }
        return reduceMotion || lowPower.isEnabled() ? .still : .animated
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
        appearanceMode = DashboardAppearance(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .system
        gardenMode = GardenMode(rawValue: defaults.string(forKey: Self.gardenKey) ?? "") ?? .animated
        NSApp?.appearance = appearanceMode.nativeAppearance
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
}

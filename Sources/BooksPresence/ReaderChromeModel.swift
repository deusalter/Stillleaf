import AppKit
import Combine

/// One control the renderer describes: a choice, a number or a toggle. The native panels are built from these.
struct ReaderControlDefinition: Decodable, Identifiable {
    /// `background`, `text` and `alternate` are set on page themes, which the panel draws as swatches.
    struct Option: Decodable, Identifiable {
        let value: String; let label: String
        let background: String?; let text: String?; let alternate: String?
        var id: String { value }
    }
    let key: String
    let label: String
    let kind: String
    let options: [Option]?
    let min: Double?
    let max: Double?
    let step: Double?
    let nullable: Bool?
    var id: String { key }
}

@MainActor final class ReaderChromeModel: ObservableObject {
    @Published var preferences: [String: Any] = [:]
    @Published var effectiveAppearance: [String: Any] = [:]
    /// The panel and accent colours of the page theme, which tint the native panel.
    @Published var panelAppearance: [String: Any] = [:]
    @Published var definitions: [ReaderControlDefinition] = []
    @Published var error: String?
    @Published var resetting = false
    var change: ((String, Any) -> Void)?
    var reset: (() -> Void)?
    /// The raw definitions last decoded: they describe the controls, not the book, and almost never change.
    private var decodedDefinitions: NSArray?
    /// Each assignment to a published property redraws every view that watches it, so an unchanged value is left alone.
    private static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }
    func accept(_ value: [String: Any]) {
        if let p = value["preferences"] as? [String: Any], !Self.same(p, preferences) { preferences = p }
        if let appearance = value["effectiveAppearance"] as? [String: Any], !Self.same(appearance, effectiveAppearance) { effectiveAppearance = appearance }
        if let appearance = value["panelAppearance"] as? [String: Any], !Self.same(appearance, panelAppearance) { panelAppearance = appearance }
        if let d = value["definitions"] {
            if let raw = d as? NSArray, let last = decodedDefinitions, raw.isEqual(last) { return }
            if let data = try? JSONSerialization.data(withJSONObject: d),
               let decoded = try? JSONDecoder().decode([ReaderControlDefinition].self, from: data) { definitions = decoded; decodedDefinitions = d as? NSArray }
        }
    }
    var panelPalette: ReaderPanelPalette { ReaderPanelPalette(appearance: effectiveAppearance.merging(panelAppearance) { $1 }) }
    func selectChoice(_ key: String, _ value: Any) {
        if key == "margins" { change?("sideMargin", NSNull()) }
        change?(key, value)
    }
    func customColor(_ key: String) -> String {
        if let current = effectiveAppearance[key] as? String { return current }
        // A disconnected/older renderer still starts with a readable system pair.
        let color = key == "backgroundColor" ? NSColor.textBackgroundColor : NSColor.textColor
        guard let rgb = color.usingColorSpace(.sRGB) else { return key == "backgroundColor" ? "#ffffff" : "#000000" }
        return String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    func encoded(_ key: String) -> String {
        guard let value = preferences[key], let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}

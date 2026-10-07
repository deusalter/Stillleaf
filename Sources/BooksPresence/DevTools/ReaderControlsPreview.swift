import AppKit
import SwiftUI

/// Offscreen renders of the reader's native Appearance panel over a page, in several page themes.
/// The definitions mirror the renderer's `nativeDefinitions`; the native chrome smoke checks the live ones.
@MainActor
func renderReaderControlPreviews(to destination: URL) throws {
    func choice(_ key: String, _ label: String, _ options: [[String: Any]]) -> [String: Any] {
        ["key": key, "label": label, "kind": "choice", "options": options]
    }
    func option(_ value: String, _ label: String, _ background: String? = nil, _ text: String? = nil, _ alternate: String? = nil) -> [String: Any] {
        var item: [String: Any] = ["value": "\"\(value)\"", "label": label]
        if let background { item["background"] = background }
        if let text { item["text"] = text }
        if let alternate { item["alternate"] = alternate }
        return item
    }
    func number(_ key: String, _ label: String, _ min: Double, _ max: Double, _ step: Double, nullable: Bool = false) -> [String: Any] {
        ["key": key, "label": label, "kind": "number", "min": min, "max": max, "step": step, "nullable": nullable]
    }
    let themes: [(id: String, label: String, background: String, text: String)] = [
        ("original", "Original", "#FFFFFF", "#1D1D1F"), ("paper", "Stillleaf", "#F0F7F3", "#183D33"), ("sepia", "Warm", "#F6F1E3", "#403B2C"),
        ("calm", "Calm", "#EEE2CC", "#3B3024"), ("focus", "Focus", "#FFFBEF", "#1C1A16"), ("quiet", "Quiet", "#4A4A4E", "#D6D6D9"),
        ("dark", "Dark", "#1C302D", "#E7F3EA"), ("night", "Night", "#0D0D0E", "#ABABAF"), ("white", "White", "#FFFFFF", "#242729"),
        ("stone", "Stone", "#E9E8E4", "#343534"), ("mist", "Mist", "#EAF1F7", "#263C50"), ("forest", "Forest", "#E4EFE6", "#234A35"),
        ("dusk", "Dusk", "#302C3A", "#EDE4F1"), ("midnight", "Midnight", "#0D121A", "#D4DAE5"), ("custom", "Custom", "#F0F7F3", "#183D33"),
    ]
    let definitions: [[String: Any]] = [
        choice("theme", "Page theme", [option("system", "System", "#F0F7F3", "#087D65", "#1C302D")] + themes.map { option($0.id, $0.label, $0.background, $0.text) }),
        choice("fontFamily", "Typeface", [option("publisher", "Original"), option("newyork", "New York"), option("sans", "San Francisco"), option("literata", "Literata")]),
        choice("margins", "Margins", [option("narrow", "Narrow"), option("normal", "Normal"), option("wide", "Wide")]),
        choice("vines", "Vines", [option("margins", "Margins"), option("off", "Off")]),
        choice("columns", "Pages", [option("one", "Single page"), option("two", "Facing pages")]),
        ["key": "fontWeight", "label": "Text weight", "kind": "choice", "options": [["value": "null", "label": "Original"], ["value": "400", "label": "Regular"], ["value": "700", "label": "Bold"]]],
        choice("textAlign", "Alignment", [option("publisher", "Original"), option("start", "Start"), option("justify", "Justified")]),
        ["key": "hyphens", "label": "Hyphenation", "kind": "choice", "options": [["value": "null", "label": "Original"], ["value": "true", "label": "On"], ["value": "false", "label": "Off"]]],
        number("fontSize", "Text size", 0.5, 3, 0.01), number("lineHeight", "Line spacing", 1, 3, 0.05), number("measure", "Line width", 20, 120, 1),
        number("contentWidth", "Page width", 40, 100, 1), number("sideMargin", "Side margins", 0, 96, 2, nullable: true),
        number("letterSpacing", "Letter spacing", 0, 1, 0.05), number("wordSpacing", "Word spacing", 0, 1, 0.05),
        ["key": "scroll", "label": "Continuous scrolling", "kind": "toggle"], ["key": "immersive", "label": "Focus reading", "kind": "toggle"],
        ["key": "backgroundColor", "label": "Page color", "kind": "color"], ["key": "textColor", "label": "Text color", "kind": "color"],
    ]
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    // The tall renders show the whole panel; the short ones show it at its real size.
    for (id, panel, open, height) in [("paper", "#F6FAF7", false, 1500.0), ("dark", "#223833", true, 2300.0), ("night", "#18181A", false, 640.0), ("sepia", "#FBF7EC", false, 640.0)] {
        guard let theme = themes.first(where: { $0.id == id }) else { continue }
        let model = ReaderChromeModel()
        model.accept([
            "definitions": definitions,
            "preferences": ["theme": id, "fontFamily": "publisher", "margins": "normal", "vines": "margins", "columns": "one", "fontWeight": NSNull(), "textAlign": "publisher",
                            "hyphens": NSNull(), "fontSize": 1.2, "lineHeight": 1.6, "measure": 65.0, "contentWidth": 100.0, "sideMargin": NSNull(),
                            "letterSpacing": 0.0, "wordSpacing": 0.0, "scroll": false, "immersive": false] as [String: Any],
            "effectiveAppearance": ["backgroundColor": theme.background, "textColor": theme.text],
            "panelAppearance": ["panelColor": panel, "accentColor": theme.text],
        ])
        let page = ReaderPanelPalette(appearance: ["backgroundColor": theme.background, "textColor": theme.text])
        let view = ZStack(alignment: .topTrailing) {
            // The page behind the panel, so the glass shows what it sits over.
            page.panel
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<Int(height / 48), id: \.self) { _ in
                    Text("The light fell across the open book. She turned a page and settled into her chair, and the long water went quiet.")
                        .font(.custom("Georgia", size: 15)).foregroundStyle(page.ink).lineLimit(2)
                }
            }
            .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ReaderAppearanceView(model: model, close: {}, initiallyOpen: open).frame(width: 380, height: height).padding(14)
        }
        .environment(\.nativePreviewOpaque, false)
        let name = "reader-appearance-\(id)\(height > 700 ? (open ? "-full-advanced" : "-full") : "")"
        try renderNativeView(AnyView(view), size: NSSize(width: 640, height: height + 40),
                             appearance: NSAppearance(named: ReaderPanelPalette(appearance: ["panelColor": panel, "textColor": theme.text]).dark ? .darkAqua : .aqua),
                             to: destination.appendingPathComponent("\(name).png"))
    }
}

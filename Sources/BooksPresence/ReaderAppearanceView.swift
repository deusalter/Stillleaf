import AppKit
import SwiftUI

struct ReaderAppearanceView: View {
    @ObservedObject var model: ReaderChromeModel
    let close: () -> Void
    /// Told when Customize opens or closes, so the panel can grow to hold it.
    var customizing: ((Bool) -> Void)?
    @State private var customizeOpen: Bool
    init(model: ReaderChromeModel, close: @escaping () -> Void, initiallyOpen: Bool = false, customizing: ((Bool) -> Void)? = nil) {
        self.model = model; self.close = close; self.customizing = customizing
        _customizeOpen = State(initialValue: initiallyOpen)
    }
    private var palette: ReaderPanelPalette { model.panelPalette }
    /// The themes on the panel's face; the rest of the saved themes wait under Customize.
    private static let faceThemes = ["system", "original", "night", "quiet", "paper", "sepia", "calm", "focus", "dark"]

    var body: some View {
        let sections = ReaderControlLayout.sections(for: model.definitions.map(\.key))
        let themes = model.definitions.first { $0.key == "theme" }
        let encodedFace = Set(Self.faceThemes.map { "\"\($0)\"" })
        ReaderPanelFrame(title: "Themes & Settings", close: close) {
            VStack(alignment: .leading, spacing: 12) {
                sizeAndNight
                if let themes {
                    ReaderSwatchGrid(label: themes.label, options: (themes.options ?? []).filter { encodedFace.contains($0.value) }, selection: model.encoded("theme")) { select("theme", $0) }
                }
                Button { customizeOpen.toggle(); customizing?(customizeOpen) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
                        Text("Customize").font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: ReaderPanelMetrics.controlHeight)
                    .background(Capsule().fill(palette.control)).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Customize").accessibilityValue(customizeOpen ? "expanded" : "collapsed")
                if customizeOpen {
                    if let themes {
                        ReaderPanelSection(title: "More themes") {
                            ReaderSwatchGrid(label: "More themes", options: (themes.options ?? []).filter { !encodedFace.contains($0.value) }, selection: model.encoded("theme")) { select("theme", $0) }
                        }
                    }
                    ForEach(sections.filter { $0.group != .advanced && $0.group != .theme }, id: \.group) { section in
                        ReaderPanelSection(title: section.group.title) { controls(section.keys) }
                    }
                    if let advanced = sections.first(where: { $0.group == .advanced }) {
                        ReaderPanelSection(title: ReaderControlGroup.advanced.title, showsDivider: false) { controls(advanced.keys) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Group {
                            if let error = model.error { Text(error).foregroundStyle(.red) }
                            else { Text("Saved for this book. Text stays at your current place.") }
                        }
                        .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Reset appearance") { model.reset?() }.buttonStyle(ReaderSecondaryButtonStyle())
                    }
                } else if let error = model.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .environment(\.readerPalette, palette)
        .disabled(model.resetting)
        .readingMotionAccessibility()
    }

    /// Text size in the steps of Apple Books' two A buttons, and a shortcut between a light page and Night.
    private var sizeAndNight: some View {
        let size = model.preferences["fontSize"] as? Double ?? 1.2
        func step(_ delta: Double) { model.change?("fontSize", min(3, max(0.5, ((size + delta) * 20).rounded() / 20))) }
        let shape = Capsule()
        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button { step(-0.05) } label: { Text("A").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, minHeight: ReaderPanelMetrics.controlHeight).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Smaller text")
                Rectangle().fill(palette.rim).frame(width: 1, height: 26)
                Button { step(0.05) } label: { Text("A").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: ReaderPanelMetrics.controlHeight).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Larger text")
            }
            .background(shape.fill(palette.control))
            Button { select("theme", palette.dark ? "\"original\"" : "\"night\"") } label: {
                Image(systemName: palette.dark ? "sun.max" : "moon").font(.system(size: 14, weight: .medium))
                    .frame(width: 76, height: ReaderPanelMetrics.controlHeight).background(shape.fill(palette.control)).contentShape(shape)
            }
            .buttonStyle(.plain).accessibilityLabel(palette.dark ? "Use a light page" : "Use the Night page")
        }
    }

    @ViewBuilder private func controls(_ keys: [String]) -> some View {
        ForEach(keys.filter { $0 != "columns" }, id: \.self) { key in
            if let definition = model.definitions.first(where: { $0.key == key }) { control(definition) }
        }
    }

    private func isCustomSideMargin() -> Bool {
        guard let value = model.preferences["sideMargin"] else { return false }
        return !(value is NSNull)
    }

    @ViewBuilder private func control(_ d: ReaderControlDefinition) -> some View {
        switch d.kind {
        case "choice" where d.key == "theme":
            ReaderSwatchGrid(label: d.label, options: d.options ?? [], selection: model.encoded(d.key)) { select(d.key, $0) }
        case "choice" where d.key == "fontFamily":
            HStack {
                Text(d.label).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Picker(d.label, selection: Binding(get: { model.encoded(d.key) }, set: { select(d.key, $0) })) {
                    ForEach(d.options ?? []) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
        case "choice":
            VStack(alignment: .leading, spacing: 10) {
                ReaderControlLabel(title: d.label)
                ReaderSegmented(label: d.label, options: (d.options ?? []).map { ($0.value, $0.label) },
                                selection: d.key == "margins" && isCustomSideMargin() ? nil : model.encoded(d.key)) { select(d.key, $0) }
            }
        case "toggle" where d.key == "scroll":
            ReaderReadingModePicker(mode: model.preferences["scroll"] as? Bool == true ? "continuous" : (model.preferences["columns"] as? String == "two" ? "facing" : "single")) { mode in
                model.change?("scroll", mode == "continuous")
                if mode != "continuous" { model.change?("columns", mode == "facing" ? "two" : "one") }
            }
        case "toggle":
            ReaderToggleRow(title: d.label, isOn: Binding(get: { model.preferences[d.key] as? Bool ?? false }, set: { model.change?(d.key, $0) }))
        case "number":
            if d.nullable == true {
                ReaderToggleRow(title: "Custom \(d.label.lowercased())",
                                isOn: Binding(get: { !(model.preferences[d.key] is NSNull) }, set: { model.change?(d.key, $0 ? (d.min ?? 0) as Any : NSNull()) }))
            }
            if d.nullable != true || !(model.preferences[d.key] is NSNull) {
                let current = model.preferences[d.key] as? Double ?? d.min ?? 0
                ReaderSliderRow(title: d.label, valueText: Self.valueText(d.key, current),
                                value: Binding(get: { current }, set: { model.change?(d.key, $0) }),
                                range: (d.min ?? 0)...(d.max ?? 1), step: d.step ?? 0.01)
            }
        case "color":
            VStack(alignment: .leading, spacing: 8) {
                ColorPicker(d.label, selection: Binding(get: { Color(nsColor: Self.color(model.customColor(d.key))) }, set: { value in
                    guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                    let text = String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                    model.change?(d.key, text)
                }), supportsOpacity: false)
                .font(.system(size: 12, weight: .medium))
                if d.key == "textColor" {
                    Text("Choose a page theme above to restore its colors.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }
        default: EmptyView()
        }
    }

    private func select(_ key: String, _ encoded: String) {
        if let data = encoded.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { model.selectChoice(key, decoded) }
    }

    /// The same wording the web panel shows beside each slider.
    static func valueText(_ key: String, _ value: Double) -> String {
        switch key {
        case "fontSize", "contentWidth", "letterSpacing", "wordSpacing":
            return "\(Int((key == "contentWidth" ? value : value * 100).rounded()))%"
        case "lineHeight": return String(format: "%.2f", value).replacingOccurrences(of: "0$", with: "", options: .regularExpression)
        case "measure": return "About \(Int(value.rounded())) characters"
        case "sideMargin": return "\(Int(value.rounded())) px"
        default: return String(format: "%.2f", value)
        }
    }
    private static func color(_ hex: String) -> NSColor {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0xffffff
        return NSColor(srgbRed: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, alpha: 1)
    }
}

/// Page themes as tiles, each drawn in its own colours with its name inside, three to a row like Apple Books.
private struct ReaderSwatchGrid: View {
    let label: String
    let options: [ReaderControlDefinition.Option]
    let selection: String
    let select: (String) -> Void
    @Environment(\.readerPalette) private var palette

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3), spacing: 8) {
            ForEach(options) { option in
                let on = option.value == selection
                let shape = RoundedRectangle(cornerRadius: ReaderPanelMetrics.tileRadius, style: .continuous)
                Button { select(option.value) } label: {
                    VStack(spacing: 2) {
                        Text("Aa").font(.custom("New York", size: 18))
                        Text(option.label).font(.system(size: 10.5, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(Self.color(option.text))
                    .frame(maxWidth: .infinity).frame(height: ReaderPanelMetrics.tileHeight)
                    .background(swatch(option, shape))
                    .overlay(shape.strokeBorder(on ? palette.ink : palette.rim, lineWidth: on ? 2 : 1))
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func swatch(_ option: ReaderControlDefinition.Option, _ shape: RoundedRectangle) -> some View {
        let page = Self.color(option.background)
        if let second = option.alternate.map(Self.color) { HStack(spacing: 0) { page; second }.clipShape(shape) } else { shape.fill(page) }
    }

    private static func color(_ hex: String?) -> Color {
        guard let hex, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return Color(white: 0.5) }
        return Color(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, opacity: 1)
    }
}

/// Continuous, Single page and Facing pages, drawn as the pages they produce.
private struct ReaderReadingModePicker: View {
    let mode: String
    let select: (String) -> Void
    @Environment(\.readerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReaderControlLabel(title: "Reading mode")
            HStack(spacing: 8) {
                tile("continuous", "Continuous", "One scroll through the whole book") { page(lines: 5).offset(y: 0) }
                tile("single", "Single page", "Turn one page at a time") { page(lines: 6) }
                tile("facing", "Facing pages", "Two pages side by side, like an open book") { HStack(spacing: 1) { page(lines: 6); page(lines: 6) } }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Reading mode")
        }
    }

    private func tile<G: View>(_ id: String, _ title: String, _ hint: String, @ViewBuilder glyph: () -> G) -> some View {
        ReaderTileChoice(title: title, hint: hint, on: mode == id, select: { if mode != id { select(id) } }) { glyph() }
    }

    private func page(lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<lines, id: \.self) { line in
                Capsule().fill(palette.ink.opacity(0.4)).frame(width: line == 3 ? 10 : 17, height: 1.5)
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 5)
        .frame(width: 27, height: 36, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(palette.rim, lineWidth: 0.5))
    }
}

private struct ReaderSecondaryButtonStyle: ButtonStyle {
    @Environment(\.readerPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: ReadingMetrics.Radius.control, style: .continuous)
        configuration.label.font(.system(size: 12)).foregroundStyle(palette.ink)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(shape.fill(configuration.isPressed ? palette.hover : .clear))
            .overlay(shape.strokeBorder(palette.rim, lineWidth: 1))
    }
}

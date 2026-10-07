import AppKit
import Darwin
import SwiftUI

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

/// Deterministic transport delay: reset must follow an in-flight batch and discard a later pending patch.
@MainActor func runNativeReaderQueueSmoke() async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let chrome = NativeReaderChrome(window: window)
    var commands: [String] = [], value = 1.2
    var release: CheckedContinuation<Void, Never>?
    chrome.send = { command, payload in
        commands.append(command)
        if command == "preferences" {
            await withCheckedContinuation { release = $0 }
            value = payload?["fontSize"] as? Double ?? value
        }
        if command == "reset" { value = 1.2 }
        return ["preferences": ["fontSize": value], "definitions": []]
    }
    await chrome.connect()
    chrome.model.change?("fontSize", 1.8)
    let deadline = Date().addingTimeInterval(2)
    while release == nil && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    guard let resume = release else { throw NSError(domain: "Stillleaf.ReaderControls", code: 3) }
    chrome.model.change?("fontSize", 2.1)
    chrome.model.reset?()
    resume.resume()
    try await chrome.flush()
    guard commands.filter({ $0 == "preferences" || $0 == "reset" }) == ["preferences", "reset"],
          chrome.model.preferences["fontSize"] as? Double == 1.2 else { throw NSError(domain: "Stillleaf.ReaderControls", code: 4) }
    chrome.accept(["preferences": ["fontSize": 1.2, "immersive": true]])
    guard !chrome.toolbar.isVisible else { throw NSError(domain: "Stillleaf.ReaderControls", code: 6) }
    chrome.accept(["preferences": ["fontSize": 1.2, "immersive": false], "dialogOpen": true])
    guard chrome.toolbar.isVisible, !chrome.canAcceptCommands else { throw NSError(domain: "Stillleaf.ReaderControls", code: 7) }
    chrome.model.accept(["effectiveAppearance": ["backgroundColor": "#1c302d", "textColor": "#e7f3ea"]])
    guard chrome.model.customColor("backgroundColor") == "#1c302d",
          chrome.model.customColor("textColor") == "#e7f3ea" else { throw NSError(domain: "Stillleaf.ReaderControls", code: 16) }
    chrome.model.accept(["preferences": ["theme": "white", "textColor": "#e7f3ea"],
                         "effectiveAppearance": ["backgroundColor": "#ffffff", "textColor": "#242729"]])
    guard chrome.model.customColor("textColor") == "#242729" else { throw NSError(domain: "Stillleaf.ReaderControls", code: 18) }
    let presetModel = ReaderChromeModel()
    var presetChanges: [String: Any] = [:]
    presetModel.change = { key, value in presetChanges[key] = value }
    presetModel.selectChoice("margins", "narrow")
    guard presetChanges["sideMargin"] is NSNull, presetChanges["margins"] as? String == "narrow" else { throw NSError(domain: "Stillleaf.ReaderControls", code: 17) }
    chrome.disconnect()
    print("native-reader-queue: delayed slider, superseded pending patch and Reset ordering passed")
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
    func accept(_ value: [String: Any]) {
        if let p = value["preferences"] as? [String: Any] { preferences = p }
        if let appearance = value["effectiveAppearance"] as? [String: Any] { effectiveAppearance = appearance }
        if let appearance = value["panelAppearance"] as? [String: Any] { panelAppearance = appearance }
        if let d = value["definitions"], let data = try? JSONSerialization.data(withJSONObject: d),
           let decoded = try? JSONDecoder().decode([ReaderControlDefinition].self, from: data) { definitions = decoded }
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

struct ReaderAppearanceView: View {
    @ObservedObject var model: ReaderChromeModel
    let close: () -> Void
    @State private var advancedOpen: Bool
    init(model: ReaderChromeModel, close: @escaping () -> Void, initiallyOpen: Bool = false) {
        self.model = model; self.close = close
        _advancedOpen = State(initialValue: initiallyOpen)
    }
    private var palette: ReaderPanelPalette { model.panelPalette }

    var body: some View {
        let sections = ReaderControlLayout.sections(for: model.definitions.map(\.key))
        ReaderPanelFrame(title: "Appearance", close: close) {
            ForEach(sections.filter { $0.group != .advanced }, id: \.group) { section in
                ReaderPanelSection(title: section.group.title) { controls(section.keys) }
            }
            if let advanced = sections.first(where: { $0.group == .advanced }) {
                ReaderDisclosure(title: ReaderControlGroup.advanced.title, expanded: $advancedOpen) { controls(advanced.keys) }
            }
        } footer: {
            HStack(spacing: 14) {
                Group {
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    else { Text("Saved for this book. Text stays at your current place.") }
                }
                .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Reset appearance") { model.reset?() }
                    .buttonStyle(ReaderSecondaryButtonStyle())
            }
        }
        .environment(\.readerPalette, palette)
        .disabled(model.resetting)
        .readingMotionAccessibility()
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

/// Page themes as swatches, each drawn in its own colours like the web panel.
private struct ReaderSwatchGrid: View {
    let label: String
    let options: [ReaderControlDefinition.Option]
    let selection: String
    let select: (String) -> Void
    @Environment(\.readerPalette) private var palette

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4), spacing: 8) {
            ForEach(options) { option in
                let on = option.value == selection
                Button { select(option.value) } label: {
                    VStack(spacing: 6) {
                        swatch(option).frame(height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.rim, lineWidth: 1))
                            .overlay { if on { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.accent, lineWidth: 2).padding(-3) } }
                            .padding(3)
                        Text(option.label).font(.system(size: 10, weight: on ? .semibold : .regular)).lineLimit(1)
                            .foregroundStyle(on ? palette.ink : palette.secondary)
                    }
                    .padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func swatch(_ option: ReaderControlDefinition.Option) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let page = Self.color(option.background), second = option.alternate.map(Self.color)
        ZStack {
            if let second {
                HStack(spacing: 0) { page; second }.clipShape(shape)
            } else {
                shape.fill(page)
            }
            Text("Aa").font(.custom("Georgia", size: 15)).foregroundStyle(Self.color(option.text))
        }
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

/// Owns UI commands independently of the native tracking foreground gate.
@MainActor final class NativeReaderChrome: NSObject, NSToolbarDelegate, NSMenuItemValidation {
    let model = ReaderChromeModel()
    let toolbar = NSToolbar(identifier: "Stillleaf.reader")
    private let appearance = ReaderPopup()
    private weak var window: NSWindow?
    private var active = false
    private var closing = false
    private var dialogOpen = false
    private var failedPreference = false
    private var commandErrorAlert: NSAlert?
    private var bookmarked = false
    private var connectionGeneration = 0
    private var preferenceGeneration = 0
    private var appearanceShows = 0
    private var appearanceCloses = 0
    private var resetTask: Task<Void, Never>?
    var isConnected: Bool { active }
    var canAcceptCommands: Bool { active && !closing && !dialogOpen && !model.resetting && commandErrorAlert == nil }
    private var pendingCommands: Set<String> = []
    private var pending: [String: Any] = [:]
    private var preferenceTask: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?
    var send: ((String, [String: Any]?) async throws -> [String: Any])?
    var returnFocus: (() -> Void)?
    private let items: [(String, String, String)] = [
        ("contents", "Contents", "list.bullet"), ("search", "Search book", "magnifyingglass"),
        ("notes", "Highlights and notes", "text.badge.star"), ("previous", "Previous", "chevron.left"),
        ("next", "Next", "chevron.right"), ("bookmark", "Add bookmark", "bookmark"),
        ("focus", "Focus reading", "arrow.up.left.and.arrow.down.right"), ("appearance", "Appearance", "textformat.size")
    ]
    init(window: NSWindow) {
        self.window = window
        super.init()
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.toolbarStyle = .unified; toolbar.isVisible = false
        appearance.install(ReaderAppearanceView(model: model, close: { [weak self] in self?.appearance.close() }), size: NSSize(width: 380, height: 640))
        appearance.didShow = { [weak self] in self?.appearanceShows += 1 }
        appearance.didClose = { [weak self] in self?.appearanceCloses += 1; self?.returnFocus?() }
        appearance.anchorHit = { [weak self] event in self?.hitsAppearanceButton(event) ?? false }
        model.change = { [weak self] key, value in self?.updatePreference(key, value) }
        model.reset = { [weak self] in self?.resetAppearance() }
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.sendPolicy() } }
        updateEnabled()
    }
    func connect() async {
        guard let send else { return }
        let generation = connectionGeneration
        do {
            let value = try await send("activate", nil)
            guard generation == connectionGeneration else { return }
            guard !closing else {
                // Activation already hid the renderer controls. A failed close
                // must retain one usable surface even though native ownership
                // was never accepted. Successful close disposes both surfaces.
                _ = try? await send("deactivate", nil)
                return
            }
            active = true; accept(value); updateEnabled(); sendPolicy()
        } catch {
            guard generation == connectionGeneration else { return }
            active = false; updateEnabled()
            _ = try? await send("deactivate", nil)
            model.error = "Native controls could not connect. The book controls remain available."
        }
    }
    func accept(_ value: [String: Any]) {
        model.accept(value); dialogOpen = value["dialogOpen"] as? Bool ?? false
        appearance.setDark(model.panelPalette.dark)
        bookmarked = value["bookmarked"] as? Bool ?? false
        for item in toolbar.items {
            if let button = item.view as? NSButton {
                if item.itemIdentifier.rawValue == "bookmark" { button.state = bookmarked ? .on : .off }
                if item.itemIdentifier.rawValue == "focus" { button.state = model.preferences["immersive"] as? Bool == true ? .on : .off }
            }
        }
        updateEnabled()
    }
    func disconnect() { connectionGeneration += 1; active = false; resetTask?.cancel(); preferenceTask?.cancel(); pending.removeAll(); pendingCommands.removeAll(); appearance.close(); dismissCommandError(); updateEnabled() }
    func command(_ name: String) {
        guard canAcceptCommands, !pendingCommands.contains(name), send != nil else { return }
        // Native feedback is immediate; selection still requires the renderer's
        // acknowledgement. Disable this command to prevent a duplicate toggle.
        pendingCommands.insert(name); updateEnabled()
        let generation = connectionGeneration
        Task { [weak self] in
            guard let self, let send else { return }
            defer { if generation == connectionGeneration { pendingCommands.remove(name); updateEnabled() } }
            guard active, generation == connectionGeneration else { return }
            do { let value = try await send(name, nil); guard active, !closing, generation == connectionGeneration else { return }; model.error = nil; accept(value) }
            catch { if active, !closing, generation == connectionGeneration { showCommandError(name) } }
        }
    }
    private func showCommandError(_ command: String) {
        model.error = "The reader did not confirm the action. Check the page or bookmark before trying again."
        guard commandErrorAlert == nil, let window else { return }
        let alert = NSAlert()
        alert.messageText = "The reader did not confirm the action"
        alert.informativeText = "Check the page or bookmark before trying again."
        alert.addButton(withTitle: "Try again")
        alert.addButton(withTitle: "Cancel")
        commandErrorAlert = alert; updateEnabled()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.commandErrorAlert = nil; self.updateEnabled()
            if response == .alertFirstButtonReturn { self.command(command) }
            else { self.returnFocus?() }
        }
    }
    private func dismissCommandError() {
        guard let alert = commandErrorAlert else { return }
        window?.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        commandErrorAlert = nil
    }
    private func updatePreference(_ key: String, _ value: Any) {
        guard active, !closing, !model.resetting else { return }
        model.preferences[key] = value; pending[key] = value
        guard preferenceTask == nil else { return }
        preferenceTask = Task { [weak self] in
            guard let self else { return }
            while !pending.isEmpty && active && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard active, !Task.isCancelled, let send else { break }
                let patch = pending, generation = preferenceGeneration; pending.removeAll()
                do { let value = try await send("preferences", patch); guard active else { break }; if generation != preferenceGeneration { continue }; accept(value); failedPreference = false; for (key, value) in pending { model.preferences[key] = value }; model.error = nil }
                catch { failedPreference = true; model.error = "Appearance could not be saved. Try again." }
            }
            preferenceTask = nil
        }
    }
    private func resetAppearance() {
        guard active, !closing, !model.resetting else { return }
        preferenceGeneration += 1; pending.removeAll(); model.resetting = true; updateEnabled()
        let previous = preferenceTask
        resetTask = Task { [weak self] in
            guard let self else { return }
            await previous?.value
            defer { model.resetting = false; resetTask = nil; updateEnabled() }
            guard active, !Task.isCancelled, let send else { return }
            do { let value = try await send("reset", nil); guard active else { return }; accept(value); failedPreference = false; model.error = nil }
            catch { failedPreference = true; model.error = "Appearance could not be reset. Try again." }
        }
    }
    func setClosing(_ value: Bool) { closing = value; updateEnabled() }
    func flush() async throws {
        if let resetTask { await resetTask.value }
        if let preferenceTask { await preferenceTask.value }
        if failedPreference { throw NSError(domain: "Stillleaf.ReaderControls", code: 1, userInfo: [NSLocalizedDescriptionKey: "The latest appearance change did not finish."]) }
    }
    func owns(_ candidate: NSWindow?) -> Bool { appearance.isShown && candidate != nil && appearance.window === candidate }
    func openAppearance() {
        guard active, !closing, !dialogOpen, let window else { return }
        if appearance.isShown { appearance.close(); return }
        // The click that closed the panel by landing on its own button must not reopen it.
        if appearance.consumeReopenSuppression() { return }
        appearance.setDark(model.panelPalette.dark)
        appearance.show(over: window)
    }
    private func hitsAppearanceButton(_ event: NSEvent) -> Bool {
        guard let button = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "appearance" })?.view else { return false }
        return button.convert(button.bounds, to: nil).contains(event.locationInWindow)
    }
    private func sendPolicy() {
        guard active, let send else { return }
        let workspace = NSWorkspace.shared
        appearance.animates = !workspace.accessibilityDisplayShouldReduceMotion
        let policy = ["reduceMotion": workspace.accessibilityDisplayShouldReduceMotion, "reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency, "increaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast]
        Task { _ = try? await send("policy", policy) }
    }
    private func updateEnabled() {
        toolbar.isVisible = active && model.preferences["immersive"] as? Bool != true
        for item in toolbar.items {
            let enabled = canAcceptCommands && !pendingCommands.contains(item.itemIdentifier.rawValue)
            item.isEnabled = enabled; (item.view as? NSButton)?.isEnabled = enabled
        }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { items.map { .init($0.0) } + [.flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("contents"), .init("search"), .init("notes"), .flexibleSpace, .init("previous"), .init("next"), .init("bookmark"), .init("focus"), .init("appearance")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let spec = items.first(where: { $0.0 == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id); item.label = spec.1; item.paletteLabel = spec.1; item.toolTip = spec.1
        let image = NSImage(systemSymbolName: spec.2, accessibilityDescription: spec.1) ?? NSImage()
        let button = NSButton(image: image, target: self, action: #selector(invokeButton(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(spec.0); button.toolTip = spec.1; button.setAccessibilityLabel(spec.1)
        button.bezelStyle = .texturedRounded
        if ["bookmark", "focus"].contains(spec.0) { button.setButtonType(.toggle) }
        item.view = button
        let menu = NSMenuItem(title: spec.1, action: #selector(invokeMenu(_:)), keyEquivalent: "")
        menu.target = self; menu.representedObject = spec.0; item.menuFormRepresentation = menu
        button.isEnabled = active && !closing && !dialogOpen
        return item
    }
    @objc private func invokeButton(_ sender: NSButton) { invoke(sender.identifier?.rawValue ?? "") }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { canAcceptCommands && !pendingCommands.contains(item.representedObject as? String ?? "") }
    @objc private func invokeMenu(_ sender: NSMenuItem) { invoke(sender.representedObject as? String ?? "") }
    private func invoke(_ name: String) {
        // A toggle reflects acknowledged reader state rather than an optimistic click.
        for item in toolbar.items {
            if let button = item.view as? NSButton {
                if item.itemIdentifier.rawValue == "bookmark" { button.state = bookmarked ? .on : .off }
                if item.itemIdentifier.rawValue == "focus" { button.state = model.preferences["immersive"] as? Bool == true ? .on : .off }
            }
        }
        if name == "appearance" { openAppearance() }
        else { appearance.close(); command(name) }
    }
    func testPendingFeedback() async throws {
        guard let original = send,
              let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "bookmark" }),
              let button = item.view as? NSButton else { throw NSError(domain: "Stillleaf.ReaderControls", code: 9) }
        model.reset?()
        try await flush()
        guard canAcceptCommands, button.isEnabled else { throw NSError(domain: "Stillleaf.ReaderControls", code: 14) }
        var release: CheckedContinuation<Void, Never>?, calls = 0
        let originalState = button.state
        send = { name, payload in
            calls += 1
            await withCheckedContinuation { release = $0 }
            return try await original(name, payload)
        }
        defer { send = original; release?.resume() }
        try testClick("bookmark")
        guard !button.isEnabled, button.state == originalState else { throw NSError(domain: "Stillleaf.ReaderControls", code: 10) }
        command("bookmark")
        let deadline = Date().addingTimeInterval(3)
        while release == nil && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard calls == 1, release != nil else { throw NSError(domain: "Stillleaf.ReaderControls", code: 11) }
        release?.resume(); release = nil
        while !button.isEnabled && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard button.isEnabled, button.state != originalState else { throw NSError(domain: "Stillleaf.ReaderControls", code: 12) }
        accept(try await original("bookmark", nil))
        send = { _, _ in throw NSError(domain: "Stillleaf.SyntheticFailure", code: 1) }
        try testClick("bookmark")
        while commandErrorAlert == nil && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard let failure = commandErrorAlert, !button.isEnabled, button.state == originalState,
              model.error != nil, failure.buttons.first?.title == "Try again" else { throw NSError(domain: "Stillleaf.ReaderControls", code: 13) }
        send = original
        window?.endSheet(failure.window, returnCode: .alertFirstButtonReturn)
        let retryDeadline = Date().addingTimeInterval(3)
        while (!button.isEnabled || button.state == originalState) && Date() < retryDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard button.isEnabled, button.state != originalState, model.error == nil else { throw NSError(domain: "Stillleaf.ReaderControls", code: 15) }
        accept(try await original("bookmark", nil))
        print("native-reader-feedback: Reset re-enabled toolbar; immediate pending, duplicate suppression, acknowledged selection and explicit failure retry passed")
    }
    func benchmarkFeedback(output: URL) async throws {
        guard let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "bookmark" }), let button = item.view as? NSButton else { throw NSError(domain: "Stillleaf.Benchmark", code: 3) }
        var bookmark: [Double] = [], acknowledged: [Double] = [], panel: [Double] = [], framework: [Double] = [], dispatchCPU: [Double] = [], frameworkCPU: [Double] = []
        for sample in -2..<20 {
            let previous = button.state, start = ProcessInfo.processInfo.systemUptime
            let dispatchCPUStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            guard let action = button.action, NSApp.sendAction(action, to: button.target, from: button) else { throw NSError(domain: "Stillleaf.Benchmark", code: 4) }
            guard !button.isEnabled, button.state == previous else { throw NSError(domain: "Stillleaf.Benchmark", code: 9) }
            button.layoutSubtreeIfNeeded(); button.displayIfNeeded()
            let feedbackMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let dispatchCPUMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - dispatchCPUStart) / 1_000_000
            while (button.state == previous || !button.isEnabled) && ProcessInfo.processInfo.systemUptime - start < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
            guard button.state != previous else { throw NSError(domain: "Stillleaf.Benchmark", code: 5) }
            let layoutStart = ProcessInfo.processInfo.systemUptime
            let layoutCPUStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            button.layoutSubtreeIfNeeded(); button.displayIfNeeded()
            if sample >= 0 { bookmark.append(feedbackMs); acknowledged.append((ProcessInfo.processInfo.systemUptime - start) * 1000); framework.append((ProcessInfo.processInfo.systemUptime - layoutStart) * 1000); dispatchCPU.append(dispatchCPUMs); frameworkCPU.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - layoutCPUStart) / 1_000_000) }
            let shows = appearanceShows, closes = appearanceCloses, panelStart = ProcessInfo.processInfo.systemUptime
            openAppearance()
            while appearanceShows == shows && ProcessInfo.processInfo.systemUptime - panelStart < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
            guard appearanceShows > shows else { throw NSError(domain: "Stillleaf.Benchmark", code: 6) }
            appearance.contentView?.layoutSubtreeIfNeeded(); appearance.contentView?.displayIfNeeded()
            if sample >= 0 { panel.append((ProcessInfo.processInfo.systemUptime - panelStart) * 1000) }
            appearance.close()
            let closeStart = ProcessInfo.processInfo.systemUptime
            while appearanceCloses == closes && ProcessInfo.processInfo.systemUptime - closeStart < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
            guard appearanceCloses > closes else { throw NSError(domain: "Stillleaf.Benchmark", code: 7) }
        }
        let data = try JSONSerialization.data(withJSONObject: ["method": "20 samples, two warmups; actual AppKit bookmark action to pending disabled display, then separately acknowledged selection and display; NSPopover didShow to final layout/display", "bookmarkVisibleMs": bookmark, "bookmarkAcknowledgedMs": acknowledged, "popoverVisibleMs": panel, "buttonFrameworkMs": framework, "dispatchThreadCPUMs": dispatchCPU, "buttonFrameworkThreadCPUMs": frameworkCPU], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output)
        print("native-feedback-benchmark: 20 acknowledged bookmark actions and 20 actual popover shows recorded")
    }
    /// The Appearance panel opens under the toolbar as a child of the reader, closes on Escape and toggles from its button.
    func testAppearancePopup() async throws {
        let shows = appearanceShows, closes = appearanceCloses
        openAppearance()
        guard appearance.isShown, appearanceShows == shows + 1, let panel = appearance.window, let owner = window,
              owner.childWindows?.contains(panel) == true, owns(panel) else { throw NSError(domain: "Stillleaf.ReaderControls", code: 19) }
        let content = owner.convertToScreen(owner.contentLayoutRect)
        guard panel.frame.maxX <= owner.frame.maxX, panel.frame.maxY <= content.maxY + 0.5, panel.frame.minY >= owner.frame.minY - 0.5 else { throw NSError(domain: "Stillleaf.ReaderControls", code: 20) }
        panel.cancelOperation(nil)
        guard !appearance.isShown, appearanceCloses == closes + 1, owner.childWindows?.contains(panel) != true, !owns(panel) else { throw NSError(domain: "Stillleaf.ReaderControls", code: 21) }
        openAppearance(); openAppearance()
        guard !appearance.isShown, appearanceShows == shows + 2, appearanceCloses == closes + 2 else { throw NSError(domain: "Stillleaf.ReaderControls", code: 22) }
        print("native-reader-appearance-panel: opens under the toolbar as a child window, Escape and the toolbar button both close it")
    }
    func testCaptureAppearance(to url: URL, includeBottom: Bool = false) async throws {
        openAppearance()
        let deadline = Date().addingTimeInterval(2)
        while appearance.window?.isVisible != true && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard let panel = appearance.window, let root = appearance.contentView else { throw NSError(domain: "Stillleaf.ReaderControls", code: 5) }
        func scrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.bounds.height > scroll.contentSize.height + 1 { return scroll }
            return view.subviews.lazy.compactMap { scrollView($0) }.first
        }
        root.layoutSubtreeIfNeeded()
        let scroll = scrollView(root)
        if let scroll, let document = scroll.documentView {
            let top = document.isFlipped ? 0 : max(0, document.bounds.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: top)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
        try await captureNativeWindow(panel, to: url, contextWindow: window)
        if includeBottom {
            guard let scroll, let document = scroll.documentView else { throw NSError(domain: "Stillleaf.ReaderControls", code: 8) }
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentSize.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            try await captureNativeWindow(panel, to: url.deletingPathExtension().appendingPathExtension("bottom.png"), contextWindow: window)
        }
        appearance.close()
    }
    func testClick(_ name: String) throws {
        guard let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == name }), let button = item.view as? NSButton, button.isEnabled else {
            throw NSError(domain: "Stillleaf.ReaderControls", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native toolbar command is not available: \(name)"])
        }
        button.performClick(nil)
    }
    deinit { if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) } }
}

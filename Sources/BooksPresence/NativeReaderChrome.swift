import AppKit
import SwiftUI

struct ReaderControlDefinition: Decodable, Identifiable {
    struct Option: Decodable, Identifiable { let value: String; let label: String; var id: String { value } }
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
    @Published var definitions: [ReaderControlDefinition] = []
    @Published var error: String?
    var change: ((String, Any) -> Void)?
    var reset: (() -> Void)?
    func accept(_ value: [String: Any]) {
        if let p = value["preferences"] as? [String: Any] { preferences = p }
        if let d = value["definitions"], let data = try? JSONSerialization.data(withJSONObject: d),
           let decoded = try? JSONDecoder().decode([ReaderControlDefinition].self, from: data) { definitions = decoded }
    }
    func encoded(_ key: String) -> String {
        guard let value = preferences[key], let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}

private struct ReaderAppearanceView: View {
    @ObservedObject var model: ReaderChromeModel
    var body: some View {
        ScrollView {
            Form {
                ForEach(model.definitions) { definition in control(definition) }
                Button("Reset appearance") { model.reset?() }
                if let error = model.error { Text(error).foregroundStyle(.red).accessibilityAddTraits(.isStaticText) }
            }.formStyle(.grouped).padding(8)
        }
        .frame(width: 340, height: 440)
        .readingMotionAccessibility()
    }
    @ViewBuilder private func control(_ d: ReaderControlDefinition) -> some View {
        switch d.kind {
        case "choice" where d.key == "columns": EmptyView() // Combined Reading mode picker owns both values.
        case "choice":
            Picker(d.label, selection: Binding(get: { model.encoded(d.key) }, set: { value in
                if let data = value.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { model.change?(d.key, decoded) }
            })) { ForEach(d.options ?? []) { Text($0.label).tag($0.value) } }
        case "toggle" where d.key == "scroll":
            Picker("Reading mode", selection: Binding(get: { model.preferences["scroll"] as? Bool == true ? "continuous" : (model.preferences["columns"] as? String == "two" ? "facing" : "single") }, set: { mode in
                model.change?("scroll", mode == "continuous")
                if mode != "continuous" { model.change?("columns", mode == "facing" ? "two" : "one") }
            })) {
                Text("Continuous").tag("continuous"); Text("Single page").tag("single"); Text("Facing pages").tag("facing")
            }
        case "toggle":
            Toggle(d.label, isOn: Binding(get: { model.preferences[d.key] as? Bool ?? false }, set: { model.change?(d.key, $0) }))
        case "number":
            if d.nullable == true {
                Toggle("Custom \(d.label.lowercased())", isOn: Binding(get: { !(model.preferences[d.key] is NSNull) }, set: { model.change?(d.key, $0 ? (d.min ?? 0) as Any : NSNull()) }))
            }
            if d.nullable != true || !(model.preferences[d.key] is NSNull) {
                VStack(alignment: .leading) {
                    Text("\(d.label): \(model.preferences[d.key] as? Double ?? d.min ?? 0, specifier: "%.2f")")
                    Slider(value: Binding(get: { model.preferences[d.key] as? Double ?? d.min ?? 0 }, set: { model.change?(d.key, $0) }), in: (d.min ?? 0)...(d.max ?? 1), step: d.step ?? 0.01).accessibilityLabel(d.label)
                }
            }
        case "color":
            Toggle("Custom \(d.label.lowercased())", isOn: Binding(get: { model.preferences[d.key] is String }, set: { model.change?(d.key, $0 ? "#ffffff" as Any : NSNull()) }))
            if let hex = model.preferences[d.key] as? String {
                ColorPicker(d.label, selection: Binding(get: { Color(nsColor: Self.color(hex)) }, set: { value in
                    guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                    let text = String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                    model.change?(d.key, text)
                }), supportsOpacity: false)
            }
        default: EmptyView()
        }
    }
    private static func color(_ hex: String) -> NSColor {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0xffffff
        return NSColor(srgbRed: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, alpha: 1)
    }
}

/// Owns UI commands independently of the native tracking foreground gate.
@MainActor final class NativeReaderChrome: NSObject, NSToolbarDelegate, NSPopoverDelegate {
    let model = ReaderChromeModel()
    let toolbar = NSToolbar(identifier: "Stillleaf.reader")
    private let appearance = NSPopover()
    private weak var window: NSWindow?
    private var active = false
    private var closing = false
    private var dialogOpen = false
    private var failedPreference = false
    private var bookmarked = false
    var isConnected: Bool { active }
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
        window.toolbar = toolbar; window.toolbarStyle = .unified
        appearance.behavior = .transient; appearance.delegate = self
        appearance.contentViewController = NSHostingController(rootView: ReaderAppearanceView(model: model))
        model.change = { [weak self] key, value in self?.updatePreference(key, value) }
        model.reset = { [weak self] in self?.command("reset") }
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.sendPolicy() } }
        updateEnabled()
    }
    func connect() async {
        guard let send else { return }
        do { let value = try await send("activate", nil); active = true; accept(value); updateEnabled(); sendPolicy() }
        catch { model.error = "Native controls could not connect. The book controls remain available."; active = false; updateEnabled() }
    }
    func accept(_ value: [String: Any]) {
        model.accept(value); dialogOpen = value["dialogOpen"] as? Bool ?? false
        bookmarked = value["bookmarked"] as? Bool ?? false
        for item in toolbar.items {
            if let button = item.view as? NSButton {
                if item.itemIdentifier.rawValue == "bookmark" { button.state = bookmarked ? .on : .off }
                if item.itemIdentifier.rawValue == "focus" { button.state = model.preferences["immersive"] as? Bool == true ? .on : .off }
            }
        }
        updateEnabled()
    }
    func disconnect() { active = false; preferenceTask?.cancel(); pending.removeAll(); appearance.close(); updateEnabled() }
    func command(_ name: String) {
        guard active, !closing else { return }
        Task { [weak self] in
            guard let self, let send, active else { return }
            do { let value = try await send(name, nil); guard active, !closing else { return }; model.error = nil; accept(value) }
            catch { model.error = "The reader command could not finish. Try again." }
        }
    }
    private func updatePreference(_ key: String, _ value: Any) {
        guard active, !closing else { return }
        model.preferences[key] = value; pending[key] = value
        guard preferenceTask == nil else { return }
        preferenceTask = Task { [weak self] in
            guard let self else { return }
            while !pending.isEmpty && active && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard active, !Task.isCancelled, let send else { break }
                let patch = pending; pending.removeAll()
                do { let value = try await send("preferences", patch); guard active else { break }; accept(value); failedPreference = false; for (key, value) in pending { model.preferences[key] = value }; model.error = nil }
                catch { failedPreference = true; model.error = "Appearance could not be saved. Try again." }
            }
            preferenceTask = nil
        }
    }
    func setClosing(_ value: Bool) { closing = value; updateEnabled() }
    func flush() async throws {
        if let preferenceTask { await preferenceTask.value }
        if failedPreference { throw NSError(domain: "Stillleaf.ReaderControls", code: 1, userInfo: [NSLocalizedDescriptionKey: "The latest appearance change did not finish."]) }
    }
    func owns(_ candidate: NSWindow?) -> Bool { appearance.isShown && candidate != nil && appearance.contentViewController?.view.window === candidate }
    func openAppearance() {
        guard active, !closing, !dialogOpen, let view = window?.contentView else { return }
        if appearance.isShown { appearance.close(); return }
        let y = view.isFlipped ? view.bounds.minY + 8 : view.bounds.maxY - 8
        appearance.show(relativeTo: NSRect(x: view.bounds.maxX - 40, y: y, width: 1, height: 1), of: view, preferredEdge: .maxY)
    }
    private func sendPolicy() {
        guard active, let send else { return }
        let workspace = NSWorkspace.shared
        let policy = ["reduceMotion": workspace.accessibilityDisplayShouldReduceMotion, "reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency, "increaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast]
        Task { _ = try? await send("policy", policy) }
    }
    private func updateEnabled() { for item in toolbar.items { item.isEnabled = active && !closing && !dialogOpen; (item.view as? NSButton)?.isEnabled = active && !closing && !dialogOpen } }
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
    func popoverDidClose(_ notification: Notification) { returnFocus?() }
    func testClick(_ name: String) throws {
        guard let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == name }), let button = item.view as? NSButton, button.isEnabled else {
            throw NSError(domain: "Stillleaf.ReaderControls", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native toolbar command is not available: \(name)"])
        }
        button.performClick(nil)
    }
    deinit { if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) } }
}

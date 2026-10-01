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
        case "choice":
            Picker(d.label, selection: Binding(get: { model.encoded(d.key) }, set: { value in
                if let data = value.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { model.change?(d.key, decoded) }
            })) { ForEach(d.options ?? []) { Text($0.label).tag($0.value) } }
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
        displayObserver = NotificationCenter.default.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.sendPolicy() } }
        updateEnabled()
    }
    func connect() async {
        guard let send else { return }
        do { let value = try await send("activate", nil); active = true; model.accept(value); updateEnabled(); sendPolicy() }
        catch { model.error = "Native controls could not connect. The book controls remain available."; active = false; updateEnabled() }
    }
    func accept(_ value: [String: Any]) { model.accept(value) }
    func disconnect() { active = false; preferenceTask?.cancel(); pending.removeAll(); appearance.close(); updateEnabled() }
    func command(_ name: String) {
        guard active, !closing else { return }
        Task { [weak self] in
            guard let self, let send, active else { return }
            do { let value = try await send(name, nil); guard active, !closing else { return }; model.error = nil; model.accept(value) }
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
                do { let value = try await send("preferences", patch); guard active else { break }; model.accept(value); for (key, value) in pending { model.preferences[key] = value }; model.error = nil }
                catch { model.error = "Appearance could not be saved. Try again." }
            }
            preferenceTask = nil
        }
    }
    func setClosing(_ value: Bool) { closing = value; updateEnabled() }
    func flush() async {
        if let preferenceTask { await preferenceTask.value }
    }
    private func sendPolicy() {
        guard active, let send else { return }
        let workspace = NSWorkspace.shared
        let policy = ["reduceMotion": workspace.accessibilityDisplayShouldReduceMotion, "reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency, "increaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast]
        Task { _ = try? await send("policy", policy) }
    }
    private func updateEnabled() { for item in toolbar.items { item.isEnabled = active && !closing; (item.view as? NSButton)?.isEnabled = active && !closing } }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { items.map { .init($0.0) } + [.flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("contents"), .init("search"), .init("notes"), .flexibleSpace, .init("previous"), .init("next"), .init("bookmark"), .init("focus"), .init("appearance")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let spec = items.first(where: { $0.0 == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id); item.label = spec.1; item.paletteLabel = spec.1; item.toolTip = spec.1
        item.image = NSImage(systemSymbolName: spec.2, accessibilityDescription: spec.1); item.target = self; item.action = #selector(invoke(_:)); item.isEnabled = active
        return item
    }
    @objc private func invoke(_ sender: NSToolbarItem) {
        guard active, !closing else { return }
        if sender.itemIdentifier.rawValue == "appearance" {
            if appearance.isShown { appearance.close(); return }
            guard let view = sender.view ?? window?.contentView else { return }
            appearance.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        } else { appearance.close(); command(sender.itemIdentifier.rawValue) }
    }
    func popoverDidClose(_ notification: Notification) { returnFocus?() }
    deinit { if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) } }
}

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
    chrome.disconnect()
    print("native-reader-queue: delayed slider, superseded pending patch and Reset ordering passed")
}

@MainActor final class ReaderChromeModel: ObservableObject {
    @Published var preferences: [String: Any] = [:]
    @Published var definitions: [ReaderControlDefinition] = []
    @Published var error: String?
    @Published var resetting = false
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
            }.formStyle(.grouped).disabled(model.resetting).padding(8)
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
@MainActor final class NativeReaderChrome: NSObject, NSToolbarDelegate, NSPopoverDelegate, NSMenuItemValidation {
    let model = ReaderChromeModel()
    let toolbar = NSToolbar(identifier: "Stillleaf.reader")
    private let appearance = NSPopover()
    private weak var window: NSWindow?
    private var active = false
    private var closing = false
    private var dialogOpen = false
    private var failedPreference = false
    private var bookmarked = false
    private var connectionGeneration = 0
    private var preferenceGeneration = 0
    private var resetTask: Task<Void, Never>?
    var isConnected: Bool { active }
    var canAcceptCommands: Bool { active && !closing && !dialogOpen && !model.resetting }
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
        appearance.behavior = .transient; appearance.delegate = self; appearance.contentSize = NSSize(width: 340, height: 440)
        appearance.contentViewController = NSHostingController(rootView: ReaderAppearanceView(model: model))
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
            guard generation == connectionGeneration, !closing else { return }
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
        bookmarked = value["bookmarked"] as? Bool ?? false
        for item in toolbar.items {
            if let button = item.view as? NSButton {
                if item.itemIdentifier.rawValue == "bookmark" { button.state = bookmarked ? .on : .off }
                if item.itemIdentifier.rawValue == "focus" { button.state = model.preferences["immersive"] as? Bool == true ? .on : .off }
            }
        }
        updateEnabled()
    }
    func disconnect() { connectionGeneration += 1; active = false; resetTask?.cancel(); preferenceTask?.cancel(); pending.removeAll(); appearance.close(); updateEnabled() }
    func command(_ name: String) {
        guard canAcceptCommands else { return }
        Task { [weak self] in
            guard let self, let send, active else { return }
            do { let value = try await send(name, nil); guard active, !closing else { return }; model.error = nil; accept(value) }
            catch { model.error = "The reader command could not finish. Try again." }
        }
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
        preferenceGeneration += 1; pending.removeAll(); model.resetting = true
        let previous = preferenceTask
        resetTask = Task { [weak self] in
            guard let self else { return }
            await previous?.value
            defer { model.resetting = false; resetTask = nil }
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
        appearance.animates = !workspace.accessibilityDisplayShouldReduceMotion
        let policy = ["reduceMotion": workspace.accessibilityDisplayShouldReduceMotion, "reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency, "increaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast]
        Task { _ = try? await send("policy", policy) }
    }
    private func updateEnabled() { toolbar.isVisible = active && model.preferences["immersive"] as? Bool != true; for item in toolbar.items { item.isEnabled = active && !closing && !dialogOpen; (item.view as? NSButton)?.isEnabled = active && !closing && !dialogOpen } }
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
    func validateMenuItem(_ item: NSMenuItem) -> Bool { canAcceptCommands }
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
    func testCaptureAppearance(to url: URL) async throws {
        openAppearance()
        let deadline = Date().addingTimeInterval(2)
        while appearance.contentViewController?.view.window == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard let panel = appearance.contentViewController?.view.window else { throw NSError(domain: "Stillleaf.ReaderControls", code: 5) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try captureNativeWindow(panel, to: url)
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

import Foundation
import Combine

/// One appearance control the renderer describes: a choice, a number, a toggle or a colour.
struct ReaderControl: Decodable, Identifiable, Equatable {
    /// `background`, `text` and `alternate` are set on page themes, which are drawn as swatches.
    struct Option: Decodable, Identifiable, Equatable {
        /// JSON text for the value (`"night"`, `700`, `null`), exactly as the renderer sent it.
        let value: String
        let label: String
        let background: String?
        let text: String?
        let alternate: String?
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

/// One row of the reader's Contents, Bookmarks, Highlights or Search lists.
struct ReaderRow: Identifiable, Equatable {
    enum Kind: String { case outline, bookmark, note, result }

    let kind: Kind
    let id: String
    var title = ""
    var detail = ""
    var quote = ""
    var note = ""
    var before = ""
    var match = ""
    var after = ""
    var chapter = ""
    /// A CSS hex colour for a highlight.
    var colour: String?
    var current = false
    var openable = true
    /// Nesting level in the table of contents.
    var depth = 0

    /// Flattens the renderer's nested contents rows; the depth becomes the indent.
    static func outline(_ raw: [[String: Any]], depth: Int = 0) -> [ReaderRow] {
        raw.flatMap { item -> [ReaderRow] in
            guard let id = item["id"] as? String else { return [] }
            var row = ReaderRow(kind: .outline, id: id)
            row.title = item["title"] as? String ?? ""
            row.current = item["current"] as? Bool ?? false
            row.openable = item["openable"] as? Bool ?? true
            row.detail = (item["page"] as? Int).map(String.init) ?? ""
            row.depth = depth
            return [row] + outline(item["children"] as? [[String: Any]] ?? [], depth: depth + 1)
        }
    }

    static func bookmarks(_ raw: [[String: Any]]) -> [ReaderRow] {
        raw.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            var row = ReaderRow(kind: .bookmark, id: id)
            row.title = item["title"] as? String ?? ""
            row.detail = (item["detail"] as? String).flatMap(dateText) ?? ""
            return row
        }
    }

    static func notes(_ raw: [[String: Any]]) -> [ReaderRow] {
        raw.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            var row = ReaderRow(kind: .note, id: id)
            row.quote = item["quote"] as? String ?? ""
            row.note = item["note"] as? String ?? ""
            row.colour = item["color"] as? String
            return row
        }
    }

    static func results(_ raw: [[String: Any]]) -> [ReaderRow] {
        raw.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            var row = ReaderRow(kind: .result, id: id)
            row.before = item["before"] as? String ?? ""
            row.match = item["match"] as? String ?? ""
            row.after = item["after"] as? String ?? ""
            row.chapter = item["chapter"] as? String ?? ""
            return row
        }
    }

    private static func dateText(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) ?? plain.date(from: iso) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// A command the renderer refused, with its own wording.
struct ReaderControlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The rows of one reader list, with the renderer's own wording for "nothing here".
struct ReaderList: Equatable {
    var rows: [ReaderRow] = []
    var empty = ""
    var status = ""
    var loading = false
}

/// The reader's controls on iPhone and iPad: what is showing, the appearance settings and the
/// Contents, Bookmarks, Highlights and Search lists. It talks to the renderer through the same
/// versioned `nativeControl` commands as the Mac reader; the renderer owns every position, so
/// this object only ever sends row ids back.
@MainActor
final class ReaderChrome: ObservableObject {
    typealias Transport = @MainActor (_ command: String, _ payload: [String: Any]?) async throws -> [String: Any]

    enum Sheet: String, Identifiable {
        case contents, search, appearance
        var id: String { rawValue }
    }

    enum ListTab: String, CaseIterable, Identifiable {
        case outline, bookmarks, notes
        var id: String { rawValue }
        var label: String {
            switch self {
            case .outline: return "Contents"
            case .bookmarks: return "Bookmarks"
            case .notes: return "Highlights"
            }
        }
    }

    /// How far the page number and the toolbar drop below the web view's footer line on a device with a home
    /// indicator, in points: half of the unused room under the web view, and never out of the band.
    nonisolated static func footerDrop(bottomInset: Double) -> Double { min(16, max(0, bottomInset) / 2) }

    /// True once the renderer has handed its controls to this host.
    @Published private(set) var connected = false
    @Published private(set) var controlsVisible = false
    @Published var sheet: Sheet? {
        didSet {
            if sheet != nil, controlsVisible { setControlsVisible(false) }
            if sheet == nil { showPinnedControls() }
        }
    }
    @Published private(set) var preferences: [String: Any] = [:]
    @Published private(set) var controls: [ReaderControl] = []
    @Published private(set) var bookmarked = false
    /// The renderer is showing one of its own dialogs (the note editor); native controls stay out of the way.
    @Published private(set) var dialogOpen = false
    /// The page's effective colours as CSS hex, for matching the controls to the page.
    @Published private(set) var pageBackground: String?
    @Published private(set) var pageText: String?
    @Published private(set) var lists: [ListTab: ReaderList] = [:]
    @Published private(set) var search = ReaderList()
    /// What the reader last searched this book for; kept while the book is open.
    @Published var searchQuery = ""
    @Published var error: String?

    /// Sends one command to the renderer. Set by the reader's view controller.
    var transport: Transport?
    /// Asks the reader to save and close. Set by the reader's view controller.
    var close: (() -> Void)?
    /// Accessibility settings the page should follow (`reduceMotion`, `increaseContrast`, …).
    var accessibility: () -> [String: Bool] = { [:] }
    /// True while VoiceOver or Switch Control is running: the controls then stay on screen.
    var keepsControls: () -> Bool = { false }
    /// Where the appearance chosen last is kept, so a book opened for the first time starts with it.
    var defaults: UserDefaults?
    /// Appearance applied when a book has no saved reader state of its own.
    var firstOpenPreferences: [String: Any] = [:]

    static let defaultsKey = "readerAppearanceDefaults"
    /// The settings that follow the reader from book to book. Position, notes and custom gutters stay per book.
    static let carriedKeys = ["theme", "fontFamily", "fontSize", "lineHeight", "scroll", "margins", "fontWeight",
                              "textAlign", "hyphens", "backgroundColor", "textColor", "columns"]

    private var pending: [String: Any] = [:]
    private var flushing = false
    private var searchGeneration = 0
    private var definitionsSeen: NSArray?
    private var remembered: [String: Any] = [:]

    // MARK: - Connection

    /// Takes over the renderer's controls. Called each time the renderer reports ready.
    func connect(firstOpen: Bool) async {
        guard let transport else { return }
        do {
            accept(try await transport("activate", nil))
            connected = true
            sendPolicy()
            showPinnedControls()
            if firstOpen {
                let start = Self.storedDefaults(in: defaults).merging(firstOpenPreferences) { stored, _ in stored }
                    .filter { key, value in !Self.same(preferences[key], value) }
                if !start.isEmpty { accept(try await transport("preferences", start)) }
            }
        } catch {
            connected = false
        }
    }

    /// The renderer went away (closed, or its process was reclaimed). Lists are stale; settings stay on screen.
    func disconnect() {
        connected = false
        controlsVisible = false
        pending = [:]
        lists = [:]
        search = ReaderList()
    }

    /// Applies UI state from a command's response or from a `chrome` event.
    func accept(_ value: [String: Any]) {
        if let latest = value["preferences"] as? [String: Any], pending.isEmpty {
            if !NSDictionary(dictionary: latest).isEqual(to: preferences) { preferences = latest }
            // A change made here was already on screen, so remember what the renderer settled on either way.
            if connected { remember(latest) }
        }
        if let appearance = value["effectiveAppearance"] as? [String: Any] {
            let background = appearance["backgroundColor"] as? String, text = appearance["textColor"] as? String
            if background != pageBackground { pageBackground = background }
            if text != pageText { pageText = text }
        }
        if let saved = value["bookmarked"] as? Bool, saved != bookmarked { bookmarked = saved }
        if let open = value["dialogOpen"] as? Bool, open != dialogOpen {
            dialogOpen = open
            if open, controlsVisible { setControlsVisible(false) }
            if !open { showPinnedControls() }
        }
        if let raw = value["definitions"] as? NSArray, definitionsSeen.map({ !raw.isEqual($0) }) ?? true,
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode([ReaderControl].self, from: data) {
            definitionsSeen = raw
            controls = decoded
        }
    }

    /// True when the page is dark, so controls and sheets over it should be too.
    var pageIsDark: Bool {
        guard let rgb = pageBackground.flatMap(Self.rgb) else { return false }
        return 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue < 0.4
    }

    /// Parses `#rrggbb` into components from 0 to 1.
    nonisolated static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    // MARK: - Controls

    func toggleControls() {
        guard connected, !dialogOpen else { return }
        setControlsVisible(!controlsVisible)
    }

    /// With VoiceOver or Switch Control there is no "tap the middle of the page", so the controls stay up
    /// whenever no sheet or note editor is in front.
    func setControlsVisible(_ visible: Bool) {
        let visible = visible || (pinned && sheet == nil && !dialogOpen)
        guard controlsVisible != visible else { return }
        controlsVisible = visible
        sendPolicy()
    }

    /// True while an assistive technology needs the controls kept on screen.
    var pinned: Bool { keepsControls() }

    private func showPinnedControls() {
        if connected, pinned, sheet == nil, !dialogOpen { setControlsVisible(true) }
    }

    /// The next or previous page, for the page buttons shown while the controls are pinned.
    func turn(forward: Bool) {
        run { transport in self.accept(try await transport(forward ? "next" : "previous", nil)) }
    }

    func open(_ sheet: Sheet) {
        guard connected, !dialogOpen else { return }
        self.sheet = sheet
    }

    func toggleBookmark() {
        run { transport in self.accept(try await transport("bookmark", nil)) }
    }

    /// The page follows the system accessibility settings and shows "of N" beside the page while controls are up.
    private func sendPolicy() {
        guard connected, let transport else { return }
        var policy = accessibility()
        policy["touch"] = true
        policy["fullScreen"] = true
        policy["controlsVisible"] = controlsVisible
        Task { _ = try? await transport("policy", policy) }
    }

    func accessibilityChanged() {
        objectWillChange.send()
        sendPolicy()
        showPinnedControls()
    }

    // MARK: - Lists

    func load(_ tab: ListTab) {
        if lists[tab] == nil { lists[tab] = ReaderList(loading: true) }
        run { transport in
            let value = try await transport("panel", ["name": tab.rawValue])
            self.accept(value)
            self.apply(value["panel"] as? [String: Any])
        }
    }

    func find(_ query: String) {
        searchGeneration += 1
        let generation = searchGeneration
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            search = ReaderList(status: text.isEmpty ? "" : "Enter at least two characters.")
            return
        }
        search.loading = true
        run { transport in
            let value = try await transport("find", ["query": String(text.prefix(200))])
            guard generation == self.searchGeneration, let panel = value["panel"] as? [String: Any], panel["stale"] as? Bool != true else { return }
            self.search = ReaderList(rows: ReaderRow.results(panel["rows"] as? [[String: Any]] ?? []),
                                     status: panel["status"] as? String ?? "")
        }
    }

    /// Opens a row's place in the book and puts the lists away.
    func go(_ row: ReaderRow) {
        guard row.openable else { return }
        run { transport in
            self.accept(try await transport("go", ["kind": row.kind.rawValue, "id": row.id]))
            self.sheet = nil
        }
    }

    func remove(_ row: ReaderRow) {
        guard row.kind == .bookmark || row.kind == .note else { return }
        run { transport in
            let value = try await transport("remove", ["kind": row.kind.rawValue, "id": row.id])
            self.accept(value)
            self.apply(value["panel"] as? [String: Any])
        }
    }

    private func apply(_ panel: [String: Any]?) {
        guard let panel, let name = panel["name"] as? String, let tab = ListTab(rawValue: name) else { return }
        let raw = panel["rows"] as? [[String: Any]] ?? []
        let rows: [ReaderRow]
        switch tab {
        case .outline: rows = ReaderRow.outline(raw)
        case .bookmarks: rows = ReaderRow.bookmarks(raw)
        case .notes: rows = ReaderRow.notes(raw)
        }
        lists[tab] = ReaderList(rows: rows, empty: panel["empty"] as? String ?? "")
    }

    // MARK: - Appearance

    func control(_ key: String) -> ReaderControl? { controls.first { $0.key == key } }
    func number(_ key: String) -> Double? { (preferences[key] as? NSNumber)?.doubleValue }
    func flag(_ key: String) -> Bool { preferences[key] as? Bool ?? false }

    /// The current value of a preference as JSON text, the form choice options use.
    func encoded(_ key: String) -> String {
        guard let value = preferences[key], !(value is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    func isSelected(_ option: ReaderControl.Option, for key: String) -> Bool { encoded(key) == option.value }

    func choose(_ option: ReaderControl.Option, for key: String) {
        guard let data = option.value.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
        var patch: [String: Any] = [key: value]
        // A named theme replaces custom page colours, as in the renderer's own panel.
        if key == "theme" { patch["backgroundColor"] = NSNull(); patch["textColor"] = NSNull() }
        set(patch)
    }

    /// Moves a numeric preference by `amount`, inside the range the renderer allows.
    func step(_ key: String, by amount: Double) {
        guard let control = control(key), let current = number(key) else { return }
        let next = Swift.min(control.max ?? .greatestFiniteMagnitude, Swift.max(control.min ?? 0, current + amount))
        set([key: (next * 100).rounded() / 100])
    }

    func set(_ key: String, _ value: Any) { set([key: value]) }

    /// Shows a change at once and sends it; rapid changes (a slider) collapse into the latest values.
    func set(_ patch: [String: Any]) {
        guard connected else { return }
        var shown = preferences
        for (key, value) in patch {
            shown[key] = value
            pending[key] = value
        }
        preferences = shown
        guard !flushing else { return }
        flushing = true
        Task {
            defer { flushing = false }
            while !pending.isEmpty, let transport {
                let batch = pending
                pending = [:]
                do { accept(try await transport("preferences", batch)) } catch {
                    pending = [:]
                    report(error)
                }
            }
        }
    }

    func resetAppearance() {
        pending = [:]
        run { transport in self.accept(try await transport("reset", nil)) }
    }

    private func remember(_ preferences: [String: Any]) {
        guard let defaults else { return }
        let carried = preferences.filter { Self.carriedKeys.contains($0.key) && !($0.value is NSNull) }
        guard !NSDictionary(dictionary: carried).isEqual(to: remembered), JSONSerialization.isValidJSONObject(carried),
              let data = try? JSONSerialization.data(withJSONObject: carried) else { return }
        remembered = carried
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func storedDefaults(in defaults: UserDefaults?) -> [String: Any] {
        guard let data = defaults?.data(forKey: defaultsKey),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return value.filter { carriedKeys.contains($0.key) }
    }

    private static func same(_ lhs: Any?, _ rhs: Any) -> Bool {
        guard let lhs else { return false }
        return (lhs as AnyObject).isEqual(rhs)
    }

    // MARK: - Plumbing

    private func run(_ body: @escaping @MainActor (Transport) async throws -> Void) {
        guard connected, let transport else { return }
        Task {
            do { try await body(transport) } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        // A reader that is closing or reloading refuses commands; that is not worth an alert.
        guard connected else { return }
        let text = error.localizedDescription
        if text.contains("Finish the open reader panel") || text.contains("unavailable or invalid") || text.contains("not connected") { return }
        self.error = text
    }
}

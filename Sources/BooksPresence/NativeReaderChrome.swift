import AppKit
import Darwin
import SwiftUI

/// Owns UI commands independently of the native tracking foreground gate.
@MainActor final class NativeReaderChrome: NSObject, NSToolbarDelegate, NSMenuItemValidation {
    let model = ReaderChromeModel()
    let toolbar = NSToolbar(identifier: "Stillleaf.reader")
    private let appearance = ReaderPopup()
    private let library = ReaderPopup()
    private let searchPopup = ReaderPopup()
    let panels = ReaderPanelsModel()
    private var findTask: Task<Void, Never>?
    private var keepFocusOnClose = false
    private var popups: [ReaderPopup] { [appearance, library, searchPopup] }
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
    /// Commands that are meant to be sent again before the last one is acknowledged.
    private static let repeatableCommands: Set<String> = ["next", "previous"]
    private var pending: [String: Any] = [:]
    private var preferenceTask: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?
    var send: ((String, [String: Any]?) async throws -> [String: Any])?
    var returnFocus: (() -> Void)?
    /// The toolbar, laid out as in Apple Books: a group for finding your place, the title, a group for how it reads, and the bookmark on its own.
    private let leftGroup: [ToolbarSpec] = [("contents", "Contents", "list.bullet"), ("bookmarks", "Bookmarks", "bookmark.square"), ("notes", "Highlights and notes", "note.text")]
    private let rightGroup: [ToolbarSpec] = [("appearance", "Themes and settings", "textformat.size"), ("search", "Search book", "magnifyingglass")]
    private let bookmarkItem: ToolbarSpec = ("bookmark", "Bookmark this page", "bookmark")
    private typealias ToolbarSpec = (String, String, String)
    private var buttons: [String: NSButton] = [:]
    private var capsules: [ReaderToolbarCapsule] = []
    private let titleField = NSTextField(labelWithString: "")
    let visibility: ReaderChromeVisibility
    private var fullScreen = false
    init(window: NSWindow) {
        self.window = window
        visibility = ReaderChromeVisibility(window: window)
        super.init()
        visibility.changed = { [weak self] _ in self?.sendPolicy() }
        titleField.stringValue = window.title
        titleField.font = .systemFont(ofSize: 13, weight: .semibold); titleField.lineBreakMode = .byTruncatingTail
        titleField.alignment = .center
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifier = .init("title")
        window.titleVisibility = .hidden
        window.toolbar = toolbar; window.toolbarStyle = .unified; toolbar.isVisible = false
        appearance.install(ReaderAppearanceView(model: model, close: { [weak self] in self?.appearance.close() },
                                                customizing: { [weak self] open in self?.appearance.setHeight(open ? ReaderPanelMetrics.customizeHeight : ReaderPanelMetrics.appearanceHeight) }),
                           size: NSSize(width: ReaderPanelMetrics.width, height: ReaderPanelMetrics.appearanceHeight))
        appearance.didShow = { [weak self] in self?.appearanceShows += 1 }
        appearance.didClose = { [weak self] in self?.appearanceCloses += 1; self?.returnFocus?() }
        appearance.anchorHit = { [weak self] event in self?.hitsButton("appearance", event) ?? false }
        appearance.setTitle("Themes and settings")
        appearance.didChange = { [weak self] in self?.updateHold() }
        library.didChange = { [weak self] in self?.updateHold() }
        searchPopup.didChange = { [weak self] in self?.updateHold() }
        library.install(ReaderLibraryPanelView(chrome: model, panels: panels, close: { [weak self] in self?.library.close() }), size: NSSize(width: ReaderPanelMetrics.width, height: ReaderPanelMetrics.listHeight))
        library.setTitle("Contents and saved passages")
        library.didClose = { [weak self] in self?.panelClosed() }
        library.anchorHit = { [weak self] event in
            guard let self else { return false }
            return hitsButton(panels.tab == .notes ? "notes" : panels.tab == .bookmarks ? "bookmarks" : "contents", event)
        }
        searchPopup.install(ReaderSearchPanelView(chrome: model, panels: panels, close: { [weak self] in self?.searchPopup.close() }), size: NSSize(width: ReaderPanelMetrics.width, height: ReaderPanelMetrics.searchHeight))
        searchPopup.setTitle("Search this book")
        searchPopup.didClose = { [weak self] in self?.panelClosed() }
        searchPopup.anchorHit = { [weak self] event in self?.hitsButton("search", event) ?? false }
        panels.load = { [weak self] tab in self?.loadPanel(tab) }
        panels.queryChanged = { [weak self] query in self?.scheduleFind(query) }
        panels.open = { [weak self] row in self?.openRow(row) }
        panels.remove = { [weak self] row in self?.removeRow(row) }
        panels.edit = { [weak self] row in self?.editRow(row) }
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
        popups.forEach { $0.setDark(model.panelPalette.dark) }
        bookmarked = value["bookmarked"] as? Bool ?? false
        buttons["bookmark"]?.state = bookmarked ? .on : .off
        applyToolbarPalette()
        updateHold()
        updateEnabled()
    }
    func disconnect() { connectionGeneration += 1; active = false; resetTask?.cancel(); preferenceTask?.cancel(); pending.removeAll(); pendingCommands.removeAll(); findTask?.cancel(); closePanels(); dismissCommandError(); updateEnabled() }
    func command(_ name: String) {
        let repeatable = Self.repeatableCommands.contains(name)
        guard canAcceptCommands, repeatable || !pendingCommands.contains(name), send != nil else { return }
        // Native feedback is immediate; selection still requires the renderer's
        // acknowledgement. Disable this command to prevent a duplicate toggle.
        // Page turns are the exception: every click is a turn, and the renderer queues them.
        if !repeatable { pendingCommands.insert(name); updateEnabled() }
        let generation = connectionGeneration
        Task { [weak self] in
            guard let self, let send else { return }
            defer { if !repeatable, generation == connectionGeneration { pendingCommands.remove(name); updateEnabled() } }
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
    func owns(_ candidate: NSWindow?) -> Bool { candidate != nil && popups.contains { $0.isShown && $0.window === candidate } }
    func openAppearance() {
        guard active, !closing, !dialogOpen, let window else { return }
        if appearance.isShown { appearance.close(); return }
        // The click that closed the panel by landing on its own button must not reopen it.
        if appearance.consumeReopenSuppression() { return }
        closePanels(except: appearance)
        appearance.setDark(model.panelPalette.dark)
        appearance.show(over: window, below: anchorRect("appearance"))
    }

    /// Contents and Notes share one panel; the toolbar button for each opens it on its own tab.
    func openLibrary(_ tab: ReaderPanelsModel.Tab) {
        guard canAcceptCommands, let window, send != nil else { return }
        if library.isShown, panels.tab == tab { library.close(); return }
        library.setHeight(tab == .notes ? ReaderPanelMetrics.searchHeight : ReaderPanelMetrics.listHeight)
        if library.consumeReopenSuppression() { return }
        closePanels(except: library)
        panels.error = nil
        panels.tab = tab
        library.setDark(model.panelPalette.dark)
        if !library.isShown { library.show(over: window, below: anchorRect(tab == .notes ? "notes" : tab == .bookmarks ? "bookmarks" : "contents")) }
        loadPanel(tab)
    }

    func openSearch() {
        guard canAcceptCommands, let window, send != nil else { return }
        if searchPopup.isShown { searchPopup.close(); return }
        if searchPopup.consumeReopenSuppression() { return }
        closePanels(except: searchPopup)
        panels.error = nil
        panels.resetSearch()
        searchPopup.setDark(model.panelPalette.dark)
        searchPopup.show(over: window, below: anchorRect("search"))
    }

    /// Opens whichever panel a toolbar button or menu command names. Commands that are not panels close the open one first.
    func performControl(_ name: String) { invoke(name) }

    private func closePanels(except keep: ReaderPopup? = nil) {
        for popup in popups where popup !== keep { popup.close() }
    }

    private func panelClosed() {
        findTask?.cancel()
        if keepFocusOnClose { keepFocusOnClose = false } else { returnFocus?() }
    }

    private func toolbarButton(_ name: String) -> NSView? { buttons[name] }

    /// The toolbar button's rectangle on screen, or nil when it is hidden in the toolbar's overflow menu.
    private func anchorRect(_ name: String) -> NSRect? {
        guard let view = toolbarButton(name), let host = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return host.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func hitsButton(_ name: String, _ event: NSEvent) -> Bool {
        guard let button = toolbarButton(name) else { return false }
        return button.convert(button.bounds, to: nil).contains(event.locationInWindow)
    }

    // MARK: Panel data

    private func loadPanel(_ tab: ReaderPanelsModel.Tab) {
        guard let send else { return }
        panels.markLoading(tab)
        let generation = connectionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await send("panel", ["name": tab.wireName])
                guard active, generation == connectionGeneration else { return }
                accept(value)
                panels.apply(value["panel"] as? [String: Any])
            } catch {
                guard active, generation == connectionGeneration else { return }
                panels.fail(tab)
            }
        }
    }

    /// Searches shortly after typing stops. A newer query supersedes an older one, here and in the renderer.
    private func scheduleFind(_ query: String) {
        findTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { panels.searchPrompt("Search within this book, entirely offline."); return }
        if trimmed.count < 2 { panels.searchPrompt("Enter at least two characters."); return }
        panels.searching()
        let generation = connectionGeneration
        findTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, active, generation == connectionGeneration, let send else { return }
            do {
                let value = try await send("find", ["query": query])
                guard !Task.isCancelled, active, generation == connectionGeneration else { return }
                accept(value)
                panels.apply(value["panel"] as? [String: Any])
            } catch {
                guard !Task.isCancelled, active else { return }
                panels.searchPrompt("Search could not finish. Try again.")
            }
        }
    }

    private func openRow(_ row: ReaderRow) {
        guard let send, active else { return }
        let generation = connectionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await send("go", ["kind": row.wireKind, "id": row.id])
                guard active, generation == connectionGeneration else { return }
                accept(value)
                closePanels()
            } catch {
                guard active, generation == connectionGeneration else { return }
                panels.error = "That place could not be opened."
            }
        }
    }

    private func removeRow(_ row: ReaderRow) {
        guard let send, active, row.kind == .bookmark || row.kind == .note else { return }
        let generation = connectionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await send("remove", ["kind": row.wireKind, "id": row.id])
                guard active, generation == connectionGeneration else { return }
                accept(value)
                panels.apply(value["panel"] as? [String: Any])
            } catch {
                guard active, generation == connectionGeneration else { return }
                panels.error = "That could not be removed. Try again."
            }
        }
    }

    /// The note editor stays the web dialog, so the panel hands over and does not take focus back.
    private func editRow(_ row: ReaderRow) {
        guard let send, active, row.kind == .note else { return }
        let generation = connectionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await send("editNote", ["id": row.id])
                guard active, generation == connectionGeneration else { return }
                keepFocusOnClose = true
                accept(value)
                closePanels()
                keepFocusOnClose = false
            } catch {
                guard active, generation == connectionGeneration else { return }
                panels.error = "That note could not be opened."
            }
        }
    }
    private func sendPolicy() {
        guard active, let send else { return }
        let workspace = NSWorkspace.shared
        popups.forEach { $0.animates = !workspace.accessibilityDisplayShouldReduceMotion }
        let policy = ["reduceMotion": workspace.accessibilityDisplayShouldReduceMotion, "reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency, "increaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast,
                      "controlsVisible": visibility.visible, "fullScreen": fullScreen]
        Task { _ = try? await send("policy", policy) }
    }
    private func updateEnabled() {
        toolbar.isVisible = active && model.preferences["immersive"] as? Bool != true
        for (name, button) in buttons { button.isEnabled = canAcceptCommands && !pendingCommands.contains(name) }
    }
    /// The controls stay while a panel or the note editor is open.
    private func updateHold() { visibility.hold = dialogOpen || popups.contains { $0.isShown } }
    func setFullScreen(_ value: Bool) { fullScreen = value; visibility.fullScreen = value; sendPolicy() }
    /// Icons and capsules follow the page, so a Night page gets light icons on a barely lighter capsule.
    private func applyToolbarPalette() {
        let palette = model.panelPalette
        titleField.textColor = palette.nsInk
        for button in buttons.values { button.contentTintColor = palette.nsInk }
        for capsule in capsules { capsule.apply(palette) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("group.left"), .flexibleSpace, .init("title"), .flexibleSpace, .init("group.right"), .init("group.bookmark")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id.rawValue {
        case "title":
            item.label = "Title"; item.paletteLabel = "Title"; item.view = titleField
        case "group.left": capsule(leftGroup, in: item)
        case "group.right": capsule(rightGroup, in: item)
        case "group.bookmark": capsule([bookmarkItem], in: item)
        default: return nil
        }
        applyToolbarPalette()
        return item
    }
    private func capsule(_ specs: [ToolbarSpec], in item: NSToolbarItem) {
        let row = specs.map(button(for:))
        let view = ReaderToolbarCapsule(row)
        capsules.append(view)
        item.label = specs.map(\.1).joined(separator: ", "); item.paletteLabel = item.label
        item.view = view
    }
    private func button(for spec: ToolbarSpec) -> NSButton {
        if let existing = buttons[spec.0] { return existing }
        let image = NSImage(systemSymbolName: spec.2, accessibilityDescription: spec.1) ?? NSImage()
        let button = NSButton(image: image, target: self, action: #selector(invokeButton(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(spec.0); button.toolTip = spec.1; button.setAccessibilityLabel(spec.1)
        button.isBordered = false; button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if spec.0 == "bookmark" {
            // A bookmarked page shows a solid bookmark, as in Books.
            button.setButtonType(.toggle)
            button.alternateImage = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: spec.1)
        }
        button.isEnabled = active && !closing && !dialogOpen
        buttons[spec.0] = button
        return button
    }
    @objc private func invokeButton(_ sender: NSButton) { invoke(sender.identifier?.rawValue ?? "") }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { canAcceptCommands && !pendingCommands.contains(item.representedObject as? String ?? "") }
    @objc private func invokeMenu(_ sender: NSMenuItem) { invoke(sender.representedObject as? String ?? "") }
    private func invoke(_ name: String) {
        // A toggle reflects acknowledged reader state rather than an optimistic click.
        buttons["bookmark"]?.state = bookmarked ? .on : .off
        switch name {
        case "appearance": openAppearance()
        case "contents": openLibrary(.contents)
        case "bookmarks": openLibrary(.bookmarks)
        case "notes": openLibrary(.notes)
        case "search": openSearch()
        default: closePanels(); command(name)
        }
    }
    func testPendingFeedback() async throws {
        guard let original = send, let button = buttons["bookmark"] else { throw NSError(domain: "Stillleaf.ReaderControls", code: 9) }
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
        guard let button = buttons["bookmark"] else { throw NSError(domain: "Stillleaf.Benchmark", code: 3) }
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
    /// The native Contents, Bookmarks, Notes and Search panels, against the real renderer: they open under their
    /// toolbar buttons, show the book's own rows, open a place, remove a bookmark, search, and close on Escape.
    func testPanels(evaluate: @escaping (String) async throws -> Any?, captureDirectory: URL?) async throws {
        func failure(_ code: Int, _ detail: String) -> NSError { NSError(domain: "Stillleaf.ReaderControls", code: code, userInfo: [NSLocalizedDescriptionKey: detail]) }
        func wait(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            guard condition() else { throw failure(30, "Native panel never reached: \(what)") }
        }
        func capture(_ popup: ReaderPopup, _ name: String) async throws {
            guard let captureDirectory, let panel = popup.window, let root = popup.contentView else { return }
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            try await captureNativeWindow(panel, to: captureDirectory.appendingPathComponent(name), contextWindow: window)
        }
        func bookmarkCount() async throws -> Int { try await evaluate("window.StillleafReader.exportState().bookmarks.length") as? Int ?? -1 }
        guard let owner = window else { throw failure(31, "No reader window") }

        // Contents: anchored under its button, rows from the book, no empty titles, closes when its button is pressed again.
        try testClick("contents")
        try await wait("contents rows") { library.isShown && panels.tab == .contents && !panels.page(.contents).rows.isEmpty }
        guard owner.childWindows?.contains(library.panel) == true, owns(library.window), !panels.page(.contents).rows.contains(where: { $0.title.isEmpty }) else { throw failure(32, "Contents panel is not a child window with titled rows") }
        try await capture(library, "native-panel-contents.png")
        try testClick("contents")
        guard !library.isShown else { throw failure(33, "The Contents button did not close its panel") }

        // The Notes button opens the same panel on its own tab; switching buttons keeps one panel open.
        try testClick("contents")
        try await wait("contents again") { library.isShown && !panels.page(.contents).rows.isEmpty }
        try testClick("notes")
        try await wait("notes tab") { library.isShown && panels.tab == .notes && !panels.page(.notes).loading }
        try await capture(library, "native-panel-notes.png")
        guard [appearance, searchPopup].allSatisfy({ !$0.isShown }) else { throw failure(34, "More than one panel is open") }

        // Opening a row goes there and closes the panel.
        panels.select(.contents)
        try await wait("contents rows after switching") { !panels.page(.contents).rows.isEmpty }
        guard let target = panels.page(.contents).rows.first else { throw failure(35, "No contents rows") }
        panels.open?(target)
        try await wait("panel to close after opening a row") { !library.isShown }
        guard let href = try await evaluate("window.StillleafReader.bookmark()?.href ?? ''") as? String, !href.isEmpty else { throw failure(36, "Opening a row did not navigate") }

        // Bookmarks: the bookmark button adds one, the panel lists it, and removing it removes it from the book.
        let before = try await bookmarkCount()
        try testClick("bookmark")
        let added = Date().addingTimeInterval(5)
        while try await bookmarkCount() == before && Date() < added { try await Task.sleep(nanoseconds: 25_000_000) }
        guard try await bookmarkCount() == before + 1 else { throw failure(37, "The bookmark was not added") }
        try testClick("contents")
        try await wait("library") { library.isShown }
        panels.select(.bookmarks)
        try await wait("bookmark row") { panels.page(.bookmarks).rows.count == before + 1 && !panels.page(.bookmarks).loading }
        try await capture(library, "native-panel-bookmarks.png")
        if let row = panels.page(.bookmarks).rows.first { panels.remove?(row) }
        try await wait("bookmark to be removed") { panels.page(.bookmarks).rows.count == before }
        guard try await bookmarkCount() == before else { throw failure(38, "Removing the row did not remove the bookmark") }
        library.close()

        // Search: results arrive as rows, Escape closes, and a result opens its place.
        try testClick("search")
        try await wait("search panel") { searchPopup.isShown }
        panels.query = "the"
        try await wait("search results") { !panels.results.rows.isEmpty }
        guard panels.results.status.contains("matching") else { throw failure(39, "Search status was \(panels.results.status)") }
        try await capture(searchPopup, "native-panel-search.png")
        searchPopup.panel.cancelOperation(nil)
        guard !searchPopup.isShown else { throw failure(40, "Escape did not close Search") }
        try testClick("search")
        try await wait("search again") { searchPopup.isShown }
        panels.query = "the"
        try await wait("results again") { !panels.results.rows.isEmpty }
        panels.openFirstResult()
        try await wait("search to close after opening a result") { !searchPopup.isShown }
        print("native-reader-panels: Contents, Bookmarks, Notes and Search open under their buttons, show the book's rows, open places, remove a bookmark and close on Escape")
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
        guard let button = buttons[name], button.isEnabled else {
            throw NSError(domain: "Stillleaf.ReaderControls", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native toolbar command is not available: \(name)"])
        }
        button.performClick(nil)
    }
    deinit { if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) } }
}

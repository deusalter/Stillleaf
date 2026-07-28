import AppKit
import WebKit
import BooksCore
import BooksPlatform

/// Explicit user-opened reader windows. OS import never calls this controller.
@MainActor
final class EPUBReaderWindows {
    private var windows: [String: EPUBReaderWindow] = [:]
    private var opening: [String: UUID] = [:]
    private(set) var isTerminating = false
    var didFocusReader: (() -> Void)?
    var libraryRequested: (() -> Void)?
    private let stateDirectory: URL
    private var focusedReader: EPUBReaderWindow? {
        guard NSApp.isActive else { return nil }
        return windows.values.first(where: { $0.isReady && $0.window?.isKeyWindow == true && $0.window?.isMiniaturized == false })
    }
    var focusedPublicationID: String? { focusedReader?.publication.id }
    /// The focused reader's page counter, sampled by the same page-turn tracker as Apple Books.
    var focusedPagePosition: ReaderPagePosition? { focusedReader?.pagePosition }
    init(stateDirectory: URL) { self.stateDirectory = stateDirectory }
    func open(_ publication: EPUBPublication, directory: URL, present: Bool = true) async throws {
        guard !isTerminating else { return }
        if let existing = windows[publication.id] { if present { existing.show() }; return }
        guard opening[publication.id] == nil else { return }
        let reservation = UUID(); opening[publication.id] = reservation
        defer { if opening[publication.id] == reservation { opening.removeValue(forKey: publication.id) } }
        let reader = try await EPUBReaderWindow(publication: publication, directory: directory, stateDirectory: stateDirectory)
        guard opening[publication.id] == reservation else { reader.window?.close(); return }
        reader.closed = { [weak self] in self?.windows.removeValue(forKey: publication.id) }
        reader.focused = { [weak self] in self?.didFocusReader?() }
        reader.returnToLibrary = { [weak self] in self?.libraryRequested?() }
        windows[publication.id] = reader
        if present { reader.show() }
        else { reader.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); reader.window?.orderBack(nil) }
    }
    @discardableResult
    func close(publicationID: String) async -> Bool {
        opening.removeValue(forKey: publicationID)
        guard let reader = windows[publicationID] else { return true }
        return await reader.requestClose()
    }
    func closeAll() async -> Bool {
        guard !isTerminating else { return false }
        isTerminating = true
        opening.removeAll()
        for id in Array(windows.keys) {
            if !(await close(publicationID: id)) { isTerminating = false; return false }
        }
        return true
    }
}

@MainActor
private final class EPUBReaderWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    let publication: EPUBPublication
    var window: NSWindow?
    var closed: (() -> Void)?
    var focused: (() -> Void)?
    var returnToLibrary: (() -> Void)?
    private var webView: WKWebView!
    private var guardDelegate: ReaderNavigationGuard!
    private let map: ReaderResourceMap
    private let payload: String
    private let stateURL: URL
    private let stateStore: ReaderStateStore
    private let stateWorker = DispatchQueue(label: "Stillleaf.reader-state", qos: .utility)
    private var latestState: Data?
    private var closing = false
    private let token = UUID().uuidString
    private var bridge: EPUBReaderBridge!
    private var didLoad = false
    private var startupError: String?
    private(set) var isReady = false
    private var pageCounter = 1
    private var pageLayout: String?
    private var pageVisible = 1
    /// Moves only on deliberate turns the renderer reports. A new layout key gives a new
    /// signature, so the tracker never compares pages across reflow, resize or mode changes.
    var pagePosition: ReaderPagePosition? {
        pageLayout.map { ReaderPagePosition(page: pageCounter, visiblePages: pageVisible, layoutSignature: "stillleaf-reader:" + $0) }
    }

    init(publication: EPUBPublication, directory: URL, stateDirectory: URL) async throws {
        self.publication = publication
        stateURL = stateDirectory.appendingPathComponent(publication.id + ".json")
        stateStore = ReaderStateStore(directory: stateDirectory)
        let stateURL = self.stateURL
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepare(publication: publication, directory: directory, stateURL: stateURL)
        }.value
        map = prepared.0; payload = prepared.1
        super.init()
        let configuration = try await ReaderWebViewPolicy.configuration(resources: map)
        bridge = EPUBReaderBridge(owner: self)
        configuration.userContentController.add(bridge, name: "readerEvents")
        let quotedToken = String(decoding: try JSONSerialization.data(withJSONObject: token, options: .fragmentsAllowed), as: UTF8.self)
        configuration.userContentController.addUserScript(WKUserScript(source:
            "window.addEventListener('stillleaf-reader-event', e => window.webkit.messageHandlers.readerEvents.postMessage({token: \(quotedToken), event: e.detail}));",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        guardDelegate = ReaderNavigationGuard(resources: map)
        webView.navigationDelegate = self
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = publication.title; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 520, height: 440)
        window.contentView = webView; window.isReleasedWhenClosed = false
        window.delegate = self; window.center(); self.window = window
        webView.load(URLRequest(url: map.url(for: "index.html")!))
    }

    func show() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowDidBecomeKey(_ notification: Notification) { focused?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { await requestClose() }
        return false
    }
    func requestClose() async -> Bool {
        guard !closing else { return false }
        closing = true
        defer { closing = false; window?.ignoresMouseEvents = false }
        do {
            if isReady {
                let mayClose: Any = try await withCheckedThrowingContinuation { continuation in
                    webView.callAsyncJavaScript(
                        "return window.StillleafReader.prepareClose ? await window.StillleafReader.prepareClose() : true",
                        arguments: [:], in: nil, in: .page) { result in continuation.resume(with: result) }
                }
                guard mayClose as? Bool == true else { return false }
                window?.ignoresMouseEvents = true
                window?.makeFirstResponder(nil)
                guard let snapshot = try await webView.evaluateJavaScript("JSON.stringify(window.StillleafReader.exportState())") as? String else {
                    throw ReaderStateValidation.Failure.invalidState
                }
                let data = Data(snapshot.utf8)
                try ReaderStateValidation.validate(data, publication: publication)
                latestState = data
            }
            if let data = latestState {
                let store = stateStore, publication = self.publication
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    stateWorker.async {
                        do { try store.save(data, publication: publication); continuation.resume() }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Your latest reading changes could not be saved"
            alert.informativeText = "Keep this window open to retain the current notes and reading position, or close without saving the latest changes. \(error.localizedDescription)"
            alert.addButton(withTitle: "Keep open")
            alert.addButton(withTitle: "Close without saving")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        window?.close()
        return true
    }
    func windowWillClose(_ notification: Notification) {
        stateWorker.sync {}
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readerEvents")
        closed?()
    }
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        Task { @MainActor in
            guardDelegate.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await startWhenAvailable() }
    }
    private func startWhenAvailable() async {
        guard !didLoad, webView.url == map.url(for: "index.html") else { return }
        do {
            guard try await webView.evaluateJavaScript("typeof window.StillleafReader?.open === 'function'") as? Bool == true else { return }
            guard !didLoad else { return }
            didLoad = true
            // The CLT WebKit async overlay expects nonoptional Any; returning
            // JS undefined can trap inside its generated completion wrapper.
            _ = try await webView.evaluateJavaScript("window.StillleafReader.open(\(payload)).catch(() => {}); true")
        } catch { startupError = error.localizedDescription; window?.subtitle = "This book could not open." }
    }
    func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url == map.url(for: "index.html"),
              let body = message.body as? [String: Any], body["token"] as? String == token,
              let event = body["event"] as? [String: Any] else { return }
        if event["type"] as? String == "available" { Task { await startWhenAvailable() }; return }
        guard event["editionId"] as? String == publication.id else { return }
        if event["type"] as? String == "close-request" { Task { if await requestClose() { returnToLibrary?() } }; return }
        if event["type"] as? String == "ready" { isReady = true; if window?.isKeyWindow == true { focused?() }; return }
        if event["type"] as? String == "error" { isReady = false; return }
        if event["type"] as? String == "pageLayout" || event["type"] as? String == "pageTurn" { receivePageEvidence(event); return }
        guard event["type"] as? String == "state",
              let state = event["state"] as? [String: Any], JSONSerialization.isValidJSONObject(state),
              let encoded = try? JSONSerialization.data(withJSONObject: state),
              (try? ReaderStateValidation.validate(encoded, publication: publication)) != nil else { return }
        // Position persistence is deliberately independent of activity credit.
        // Restore/reflow callbacks cannot manufacture pages or reading time.
        latestState = encoded
        let store = stateStore, publication = self.publication
        stateWorker.async { [weak self] in
            let outcome = Result { try store.save(encoded, publication: publication) }
            Task { @MainActor [weak self] in
                if case .failure = outcome { self?.window?.subtitle = "Reading changes could not be saved" }
                else { self?.window?.subtitle = "" }
            }
        }
    }

    /// The renderer reports a key per layout and each deliberate turn. The host owns the
    /// counter, so one message moves it by at most two pages and never below page one.
    private func receivePageEvidence(_ event: [String: Any]) {
        guard isReady, let layout = event["layout"] as? String, !layout.isEmpty, layout.utf8.count <= 64,
              layout.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }),
              let number = event["pages"] as? NSNumber, number.doubleValue == Double(number.intValue),
              (1...2).contains(number.intValue) else { return }
        pageLayout = layout; pageVisible = number.intValue
        guard event["type"] as? String == "pageTurn" else { return }
        switch event["direction"] as? String {
        case "forward": pageCounter = min(pageCounter + number.intValue, 10_000_000)
        case "backward": pageCounter = max(1, pageCounter - number.intValue)
        default: return
        }
    }

    nonisolated private static func prepare(publication: EPUBPublication, directory: URL, stateURL: URL) throws -> (ReaderResourceMap, String) {
        let fm = FileManager.default
        let executableFolder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Reader"), executableFolder.appendingPathComponent("Reader")].compactMap { $0 }
        // Resolve the folder first: SwiftPM's .build/release is a symlink, and the
        // enumerator reports resolved paths, so an unresolved prefix yields wrong keys.
        guard let found = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("index.html").path) }) else {
            throw EPUBImportError.invalid("Reader files are missing from this local build.")
        }
        let shell = found.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fm.enumerator(at: shell, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw EPUBImportError.invalid("Reader files are missing from this local build.")
        }
        var assets: [String: ReaderResourceMap.Asset] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw EPUBImportError.invalid("Invalid reader build resource.") }
            guard values.isRegularFile == true else { continue }
            let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard filePath.hasPrefix(shell.path + "/") else { throw EPUBImportError.invalid("Invalid reader build resource.") }
            let path = String(filePath.dropFirst(shell.path.count + 1))
            let mime: String
            switch url.pathExtension {
            case "html": mime = "text/html"; case "js": mime = "application/javascript"; case "css": mime = "text/css"
            case "json", "map": mime = "application/json"; case "svg": mime = "image/svg+xml"; case "png": mime = "image/png"
            case "woff2": mime = "font/woff2"; default: mime = "application/octet-stream"
            }
            assets[path] = .init(data: try Data(contentsOf: url), mimeType: mime)
        }
        // Publication bytes stay on disk. The renderer fetches each file through the
        // session scheme when a chapter needs it, instead of receiving the whole book.
        let resourceRoot = directory.appendingPathComponent("resources", isDirectory: true)
        let rootPath = resourceRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var total = 0
        let files: [ReaderResourceMap.FileAsset] = try publication.resources.map { item -> ReaderResourceMap.FileAsset in
            // Imported paths were validated at import; still confirm each file sits inside this edition.
            let file = resourceRoot.appendingPathComponent(item.path).standardizedFileURL
            guard !item.path.hasPrefix("/"), file.resolvingSymlinksInPath().path.hasPrefix(rootPath),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
                throw EPUBImportError.invalid("A book resource is missing. Import the book again.")
            }
            total += size
            guard size <= ReaderResourceMap.maximumFileAssetBytes, total <= 256 * 1_024 * 1_024 else { throw EPUBImportError.invalid("Book resources exceed the reader size limit.") }
            // The renderer decides from the manifest type; the response header only needs to be well formed.
            let served = ReaderResourceMap.isValidMIMEType(item.mediaType) ? item.mediaType : "application/octet-stream"
            return ReaderResourceMap.FileAsset(file: file, mimeType: served, byteCount: size)
        }
        let map = try ReaderResourceMap(resources: assets, files: files)
        guard map.url(for: "index.html") != nil else { throw EPUBImportError.invalid("Reader files are missing from this local build.") }
        let resources: [[String: Any]] = try publication.resources.enumerated().map { index, item -> [String: Any] in
            guard let url = map.fileURL(at: index) else { throw EPUBImportError.invalid("Book resources could not be prepared.") }
            return ["href": item.path, "type": item.mediaType, "url": url.absoluteString, "size": files[index].byteCount]
        }
        var input: [String: Any] = ["editionId": publication.id, "title": publication.title, "creators": publication.authors,
            "layout": publication.layout ?? "reflowable", "canReturnToLibrary": true,
            "readingOrder": publication.spine.map { path in ["href": path, "type": publication.resources.first(where: { $0.path == path })?.mediaType ?? "application/xhtml+xml"] }, "resources": resources]
        for (key, links) in [("toc", publication.toc), ("landmarks", publication.landmarks), ("pageList", publication.pageList)] {
            if let links { input[key] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(links)) }
        }
        if let language = publication.languages?.first { input["language"] = language }
        if let direction = publication.readingProgression { input["readingProgression"] = direction }
        if let data = try ReaderStateStore(directory: stateURL.deletingLastPathComponent()).load(publication: publication) {
            input["state"] = try JSONSerialization.jsonObject(with: data)
        }
        return (map, String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self))
    }
}

private final class EPUBReaderBridge: NSObject, WKScriptMessageHandler {
    weak var owner: EPUBReaderWindow?
    init(owner: EPUBReaderWindow) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak self] in self?.owner?.receive(message) }
    }
}

/// Fixture-only CLI check. Never uses the app's production store or preferences.
@MainActor
func runEPUBReaderSmoke(fixture: URL) async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-reader-smoke-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let importer = EPUBPublicationImporter(directory: temporary.appendingPathComponent("Publications"))
    let imported = try await Task.detached { try importer.importPublication(from: fixture) }.value
    let defaultsName = "Stillleaf.reader-smoke." + UUID().uuidString
    let defaults = UserDefaults(suiteName: defaultsName)!
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let model = try AppModel(support: temporary, defaults: defaults, startTracking: false)
    var presentations = 0
    model.dashboardAction = { presentations += 1 }
    model.epubLibrary.enqueue([fixture, fixture])
    let importDeadline = Date().addingTimeInterval(20)
    while model.epubLibrary.queue.isBusy && Date() < importDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
    guard model.epubLibrary.queue.summary.duplicates == 1, model.books.count == 1,
          presentations == 1, model.intervals.isEmpty, model.snapshot.phase == .paused else {
        throw EPUBImportError.invalid("Library import did not preserve one presentation and zero reading sessions.")
    }
    let journal = try ReadingStore(url: temporary.appendingPathComponent("history.sqlite"))
    let canonical = BookRecord(id: "manual:canonical-fixture", title: "Canonical journal book")
    try journal.saveBook(canonical)
    model.mergeBooks(source: model.books[0], target: canonical)
    guard model.errorMessage == nil, model.hasEPUB(canonical), model.hasImportedEPUB(canonical),
          model.epubEditions(for: canonical).map(\.id) == [imported.publication.id], model.intervals.isEmpty else {
        throw EPUBImportError.invalid("Merging an imported edition hid its EPUB actions or created reading time.")
    }
    let state = temporary.appendingPathComponent("ReaderState")
    let reader = try await EPUBReaderWindow(publication: imported.publication, directory: imported.directory, stateDirectory: state)
    defer { reader.window?.close() }
    reader.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    reader.window?.orderBack(nil)
    let deadline = Date().addingTimeInterval(20)
    var rendered = false
    while Date() < deadline {
        if let value = try? await reader.testContent(), !value.isEmpty, reader.isReady { rendered = true; break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard rendered else {
        let detail = (try? await reader.testDiagnostic()) ?? "No page diagnostics"
        throw EPUBImportError.invalid("Native reader did not render imported chapter text: \(detail)")
    }
    guard try await reader.testFixtureAssets() else {
        throw EPUBImportError.invalid("Chapter stylesheet or image did not load through the reader scheme.")
    }
    try await reader.testPageEvidence()
    if let index = CommandLine.arguments.firstIndex(of: "--reader-artifacts"), index + 1 < CommandLine.arguments.count {
        try await reader.testRenderReviewSnapshots(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
    let locationURL = state.appendingPathComponent(imported.publication.id + ".json")
    reader.flushStateForTest()
    guard FileManager.default.fileExists(atPath: locationURL.path),
          let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: locationURL)) as? [String: Any],
          let locator = saved["position"] as? [String: Any],
          let href = locator["href"] as? String, imported.publication.spine.contains(href) else {
        throw EPUBImportError.invalid("Reader location was not persisted through the authenticated bridge.")
    }
    try await reader.testAddDurableNote()
    let expectedPreferences = try await reader.testReadingModes()
    guard await reader.requestClose() else { throw EPUBImportError.invalid("Reader close did not complete.") }
    let closedState = try JSONSerialization.jsonObject(with: Data(contentsOf: locationURL)) as? [String: Any]
    guard let notes = closedState?["annotations"] as? [[String: Any]],
          notes.last?["note"] as? String == String(repeating: "N", count: 65_536),
          (closedState?["bookmarks"] as? [Any])?.count == 1 else {
        throw EPUBImportError.invalid("Immediate close lost the latest note or bookmark.")
    }
    let second = try await EPUBReaderWindow(publication: imported.publication, directory: imported.directory, stateDirectory: state)
    defer { second.window?.close() }
    second.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); second.window?.orderBack(nil)
    let restoreDeadline = Date().addingTimeInterval(20)
    var restored = false
    while Date() < restoreDeadline {
        if let value = try? await second.testHref(), value == href { restored = true; break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard restored else { throw EPUBImportError.invalid("Native reader did not restore saved chapter.") }
    guard try await second.testNoteLength() == 65_536 else {
        throw EPUBImportError.invalid("Reopened reader shortened a durable note.")
    }
    guard try await second.testPreferences() == expectedPreferences,
          try await second.testBookmarkCount() == 1 else {
        throw EPUBImportError.invalid("Reopened reader lost reading preferences or bookmark.")
    }
    try await second.testEditDraft()
    let manager = EPUBReaderWindows(stateDirectory: state)
    manager.testAdopt(second)
    let cancelledClose = Task { await manager.closeAll() }
    let draftDeadline = Date().addingTimeInterval(5)
    while !(try await second.testDraftPrompt()) && Date() < draftDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
    guard try await second.testDraftPrompt() else { throw EPUBImportError.invalid("Native close bypassed the note draft prompt.") }
    var anotherEdition = imported.publication; anotherEdition.id = String(repeating: "a", count: 64)
    try await manager.open(anotherEdition, directory: imported.directory, present: false)
    guard manager.testWindowCount == 1, manager.isTerminating else { throw EPUBImportError.invalid("Quit allowed another reader to open while awaiting a draft decision.") }
    try await second.testChooseDraft("keep-draft")
    guard !(await cancelledClose.value) else { throw EPUBImportError.invalid("Keep editing did not cancel native close.") }
    guard !manager.isTerminating else { throw EPUBImportError.invalid("Cancelled Quit left the reader manager locked.") }
    let savedClose = Task { await manager.closeAll() }
    let saveDeadline = Date().addingTimeInterval(5)
    while !(try await second.testDraftPrompt()) && Date() < saveDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
    try await second.testChooseDraft("save-draft")
    guard await savedClose.value else { throw EPUBImportError.invalid("Save draft did not complete native close.") }
    let draftSaved = try JSONSerialization.jsonObject(with: Data(contentsOf: locationURL)) as? [String: Any]
    guard (draftSaved?["annotations"] as? [[String: Any]])?.last?["note"] as? String == "Native draft preserved" else {
        throw EPUBImportError.invalid("Native close did not durably save the note draft.")
    }
    if CommandLine.arguments.contains("--reader-experimental-continuous") {
        guard imported.publication.spine.count >= 12 else { throw EPUBImportError.invalid("Continuous eviction proof needs a 12-chapter synthetic fixture.") }
        let experimental = try await EPUBReaderWindow(publication: imported.publication, directory: imported.directory, stateDirectory: state)
        defer { experimental.window?.close() }
        experimental.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); experimental.window?.orderBack(nil)
        try await experimental.testWaitUntilReady()
        try await experimental.testExperimentalContinuous()
        guard await experimental.requestClose() else { throw EPUBImportError.invalid("Continuous reader close failed.") }
        let reopened = try await EPUBReaderWindow(publication: imported.publication, directory: imported.directory, stateDirectory: state)
        defer { reopened.window?.close() }
        reopened.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); reopened.window?.orderBack(nil)
        try await reopened.testWaitUntilReady()
        try await reopened.testExperimentalContinuousRestored()
        guard await reopened.requestClose() else { throw EPUBImportError.invalid("Restored continuous reader close failed.") }
        print("epub-reader-smoke: experimental continuous co-visibility, bounded eviction, DOM-range selection note/remount, mode handoff and native reopen passed")
    }
    print("epub-reader-smoke: Library-first import, scoped rendering, three reading modes, narrow fallback, long-note/bookmark/preferences reopen, native draft cancel/save and durable close passed (synthetic; no activity credit)")
}

private extension EPUBReaderWindows {
    var testWindowCount: Int { windows.count + opening.count }
    func testAdopt(_ reader: EPUBReaderWindow) {
        let id = reader.publication.id
        windows[id] = reader
        reader.closed = { [weak self] in self?.windows.removeValue(forKey: id) }
    }
}

private extension EPUBReaderWindow {
    func testWaitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if isReady, let text = try? await testContent(), !text.isEmpty { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw EPUBImportError.invalid("Experimental fixture reader did not become ready.")
    }
    func testExperimentalContinuousRestored() async throws {
        let ok = try await webView.evaluateJavaScript("(()=>{const s=window.StillleafReader.exportState();return s.annotations.some(n=>n.note==='Native continuous selection survives remount.'&&n.locator.locations.domRange)&&s.annotations.some(n=>n.note==='Native draft preserved')&&s.bookmarks.length===1&&s.preferences.scroll===true})()") as? Bool ?? false
        guard ok else { throw EPUBImportError.invalid("Continuous state did not survive native close/reopen.") }
    }
    func testExperimentalContinuous() async throws {
        window?.setContentSize(NSSize(width: 1000, height: 850))
        let script = """
        const api=window.StillleafReader, input=JSON.parse(payload);
        const pause=ms=>new Promise(r=>setTimeout(r,ms));
        const require=(ok,message)=>{if(!ok)throw Error(message)};
        input.experimentalContinuous=true;input.state=api.exportState();input.state.preferences.scroll=true;
        input.state.position={href:input.readingOrder[0].href,type:'text/html',locations:{progression:0}};
        await api.open(input);await pause(350);
        const flow=document.querySelector('#reader');require(flow.classList.contains('continuous-reader'),'continuous gate did not activate');
        const frames=()=>[...flow.querySelectorAll('iframe')];
        flow.scrollTop=flow.querySelector('.continuous-chapter').clientHeight-flow.clientHeight/2;await pause(250);
        const [first,second]=frames(),view=flow.getBoundingClientRect();
        const last=first.contentDocument.querySelector('aside p').getBoundingClientRect(),heading=second.contentDocument.querySelector('h1').getBoundingClientRect();
        const boundary={top:view.top,bottom:view.bottom,tail:first.getBoundingClientRect().top+last.bottom,next:second.getBoundingClientRect().top+heading.top,firstFrameHeight:first.clientHeight,firstBodyBottom:first.contentDocument.body.getBoundingClientRect().bottom,firstBodyScrollHeight:first.contentDocument.body.scrollHeight,zoom:first.contentWindow.getComputedStyle(first.contentDocument.body).zoom,firstFrameTop:first.getBoundingClientRect().top};
        require(boundary.tail>view.top&&boundary.tail<view.bottom&&boundary.next>view.top&&boundary.next<view.bottom,'chapters not co-visible: '+JSON.stringify(boundary));
        const geometry=frames().map(f=>{const d=f.contentDocument,e=d.scrollingElement,b=d.body,old=e.scrollTop,before=b.getBoundingClientRect().top;e.scrollTop=100;const probe={scrollTop:e.scrollTop,bodyMoved:b.getBoundingClientRect().top-before};e.scrollTop=old;return {height:f.clientHeight,content:e.scrollHeight,clientHeight:e.clientHeight,bodyScrollHeight:b.scrollHeight,bodyHeight:b.getBoundingClientRect().height,rootHeight:d.documentElement.getBoundingClientRect().height,overflow:f.contentWindow.getComputedStyle(e).overflow,renderedBottom:Math.max(b.getBoundingClientRect().bottom,...[...b.querySelectorAll('*')].map(x=>x.getBoundingClientRect().bottom)),renderedRight:Math.max(b.getBoundingClientRect().right,...[...b.querySelectorAll('*')].map(x=>x.getBoundingClientRect().right)),probe,width:f.clientWidth,contentWidth:e.scrollWidth}});
        require(geometry.every(x=>x.probe.scrollTop===0&&Math.abs(x.probe.bodyMoved)<0.1&&x.renderedBottom<=x.height+2&&x.renderedRight<=x.width+2),'internal iframe scrolling or clipped content: '+JSON.stringify(geometry));
        const outerBefore=flow.scrollTop;first.contentDocument.dispatchEvent(new first.contentWindow.KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));await pause(150);
        require(flow.scrollTop>outerBefore&&frames().every(f=>f.contentDocument.scrollingElement.scrollTop===0),'keyboard did not scroll outer surface exclusively');
        const href=input.readingOrder[1].href;
        await api.go({href,type:'text/html',locations:{progression:0}});await pause(150);
        const frame=frames().find(f=>f.parentElement.dataset.href===href),node=frame.contentDocument.querySelector('p').firstChild;
        const range=frame.contentDocument.createRange();range.setStart(node,0);range.setEnd(node,42);
        const selection=frame.contentWindow.getSelection();selection.removeAllRanges();selection.addRange(range);
        frame.contentDocument.dispatchEvent(new frame.contentWindow.PointerEvent('pointerup',{bubbles:true,isPrimary:true}));
        document.querySelector('#note-selection').click();document.querySelector('#note-text').value='Native continuous selection survives remount.';document.querySelector('#save-note').click();
        const saved=api.exportState(),note=saved.annotations.at(-1);
        require(note.note==='Native continuous selection survives remount.'&&note.locator.href===href&&note.locator.locations.domRange,'selection note lost DOM range');
        const highlight=()=>frames().some(f=>[...(f.contentWindow.CSS.highlights?.values()??[])].some(h=>[...h].some(r=>r.toString()===note.quote)));
        require(highlight(),'selected note did not paint');
        await api.go({href:input.readingOrder[10].href,type:'text/html',locations:{progression:0}});await pause(150);
        require(frames().length<=8&&!frames().some(f=>f.parentElement.dataset.href===href),'bounded window did not evict selected chapter');
        await api.go(note.locator);await pause(150);require(highlight(),'note did not repaint after remount');
        await api.setPreferences({scroll:false,columns:'one'});require(!flow.classList.contains('continuous-reader')&&api.bookmark().href===href,'single-page handoff lost chapter');
        await api.setPreferences({scroll:true});require(flow.classList.contains('continuous-reader')&&highlight(),'continuous handoff lost highlight');
        require(JSON.stringify(api.exportState().annotations)===JSON.stringify(saved.annotations),'mode handoff changed annotations');
        require(JSON.stringify(api.exportState().bookmarks)===JSON.stringify(saved.bookmarks),'mode handoff changed bookmarks');
        return JSON.stringify({boundary,geometry,mounted:frames().length,chapters:flow.querySelectorAll('.continuous-chapter').length,noteHref:note.locator.href});
        """
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: ["payload": payload], in: nil, in: .page) { result in continuation.resume(with: result) }
        }
        let metrics = result as? String ?? "{}"
        print("epub-reader-experimental-metrics: " + metrics)
        if let index = CommandLine.arguments.firstIndex(of: "--reader-artifacts"), index + 1 < CommandLine.arguments.count {
            try Data(metrics.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]).appendingPathComponent("native-experimental-continuous-metrics.json"))
        }
    }
    /// A deliberate turn must reach the host counter under the announced layout.
    func testPageEvidence() async throws {
        let deadline = Date().addingTimeInterval(5)
        while pagePosition == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard let before = pagePosition else { throw EPUBImportError.invalid("The reader never announced its page layout.") }
        _ = try await webView.evaluateJavaScript("window.StillleafReader.next(); true")
        while (pagePosition?.page ?? 0) <= before.page && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard let after = pagePosition, after.page == before.page + before.visiblePages,
              after.layoutSignature == before.layoutSignature else {
            throw EPUBImportError.invalid("A page turn did not reach the host page counter: \(String(describing: pagePosition))")
        }
        _ = try await webView.evaluateJavaScript("window.StillleafReader.previous(); true")
        // Later checks read the chapter href, so wait for the turn back to land.
        let backDeadline = Date().addingTimeInterval(5)
        while pagePosition?.page != before.page && Date() < backDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard pagePosition?.page == before.page else {
            throw EPUBImportError.invalid("Turning back did not return to the starting page: \(String(describing: pagePosition))")
        }
    }
    /// Fixtures with `#fixture-figure` must show the lazily fetched image, styled by a fetched stylesheet.
    func testFixtureAssets() async throws -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let status = try await webView.evaluateJavaScript("(()=>{const f=[...document.querySelectorAll('#reader iframe')].find(f=>f.contentDocument?.getElementById('fixture-figure'));if(!f)return [...document.querySelectorAll('#reader iframe')].some(f=>f.contentDocument?.body?.innerText)?'absent':'pending';const i=f.contentDocument.getElementById('fixture-figure');return (i.getAttribute('src')||'').startsWith('blob:')&&i.complete&&i.naturalWidth===1&&parseFloat(f.contentWindow.getComputedStyle(i).borderLeftWidth)>0?'ok':'pending'})()") as? String ?? "pending"
            if status != "pending" { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return false
    }
    func testPreferences() async throws -> String {
        try await webView.evaluateJavaScript("JSON.stringify(window.StillleafReader.exportState().preferences)") as? String ?? ""
    }
    func testBookmarkCount() async throws -> Int {
        try await webView.evaluateJavaScript("window.StillleafReader.exportState().bookmarks.length") as? Int ?? 0
    }
    func testReadingModes() async throws -> String {
        let originalHref = try await testHref()
        var captures: [[String: Any]] = []
        for (name, width, columns, scrolling, expectedColumns) in [
            ("wide-facing", 1280, "two", false, "2"),
            ("narrow-fallback", 520, "two", false, "1"),
            ("continuous", 1000, "two", true, "auto"),
            ("single", 1000, "one", false, "1")
        ] {
            window?.setContentSize(NSSize(width: width, height: 800))
            let _: Any = try await withCheckedThrowingContinuation { continuation in
                webView.callAsyncJavaScript("await window.StillleafReader.setPreferences({columns,scroll:scrolling,fontWeight:700,textAlign:'justify',hyphens:true,letterSpacing:0.1,wordSpacing:0.2}); return true",
                    arguments: ["columns": columns, "scrolling": scrolling], in: nil, in: .page) { result in continuation.resume(with: result) }
            }
            let deadline = Date().addingTimeInterval(8)
            var metrics: [String: Any] = [:]
            repeat {
                try await Task.sleep(nanoseconds: 150_000_000)
                let value = try await webView.evaluateJavaScript("JSON.stringify((()=>{const f=[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden'&&f.contentDocument?.body);if(!f)return {};const d=f.contentDocument,s=f.contentWindow.getComputedStyle(d.documentElement);return {width:f.clientWidth,columns:s.columnCount,view:s.getPropertyValue('--USER__view').trim(),height:d.scrollingElement.scrollHeight,viewport:f.contentWindow.innerHeight,preferences:window.StillleafReader.exportState().preferences}})())") as? String ?? "{}"
                metrics = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] ?? [:]
                if scrolling ? (metrics["view"] as? String == "readium-scroll-on" && metrics["columns"] as? String == "auto") : metrics["columns"] as? String == expectedColumns { break }
            } while Date() < deadline
            let preferences = metrics["preferences"] as? [String: Any]
            guard (scrolling ? (metrics["view"] as? String == "readium-scroll-on" && metrics["columns"] as? String == "auto") : metrics["columns"] as? String == expectedColumns),
                  preferences?["columns"] as? String == columns, preferences?["scroll"] as? Bool == scrolling,
                  try await testHref() == originalHref, try await testNoteLength() == 65_536,
                  try await testBookmarkCount() == 1 else {
                throw EPUBImportError.invalid("Native reading mode \(name) failed geometry or state retention: \(metrics)")
            }
            metrics["mode"] = name; captures.append(metrics)
        }
        let data = try JSONSerialization.data(withJSONObject: captures, options: [.prettyPrinted, .sortedKeys])
        print("epub-reader-mode-metrics: " + String(decoding: data, as: UTF8.self))
        if let index = CommandLine.arguments.firstIndex(of: "--reader-artifacts"), index + 1 < CommandLine.arguments.count {
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]).appendingPathComponent("native-reading-modes-metrics.json"))
        }
        return try await testPreferences()
    }
    func testRenderReviewSnapshots(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, theme, width, height, scale) in [("native-paper", "paper", 1000, 800, 1.2), ("native-dark", "dark", 1000, 800, 1.2), ("native-narrow", "paper", 520, 600, 1.2), ("native-size100", "paper", 1000, 800, 1.0), ("native-size150", "paper", 1000, 800, 1.5)] {
            window?.setContentSize(NSSize(width: width, height: height))
            let _: Any = try await withCheckedThrowingContinuation { continuation in
                webView.callAsyncJavaScript("await window.StillleafReader.setPreferences({theme: theme, fontFamily: 'serif', fontSize: scale}); return true",
                    arguments: ["theme": theme, "scale": scale], in: nil, in: .page) { result in continuation.resume(with: result) }
            }
            try await Task.sleep(nanoseconds: 600_000_000)
            let picture: NSImage = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? EPUBImportError.invalid("Native review snapshot failed.")) }
                }
            }
            guard let tiff = picture.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw EPUBImportError.invalid("Native review image encoding failed.") }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
            if let metrics = try await webView.evaluateJavaScript("JSON.stringify(Array.from(document.querySelectorAll('#reader iframe')).map(f=>{const p=f.contentDocument?.querySelector('p');if(!p)return null;const s=f.contentWindow.getComputedStyle(p);return {frameWidth:f.clientWidth,paragraphWidth:p.getBoundingClientRect().width,fontFamily:s.fontFamily,fontSize:s.fontSize,fontWeight:s.fontWeight,lineHeight:s.lineHeight,paragraphZoom:s.zoom,bodyZoom:f.contentWindow.getComputedStyle(f.contentDocument.body).zoom,htmlZoom:f.contentWindow.getComputedStyle(f.contentDocument.documentElement).zoom}}))") as? String {
                try Data(metrics.utf8).write(to: directory.appendingPathComponent(name + "-metrics.json"))
            }
        }
    }
    func testEditDraft() async throws {
        _ = try await webView.evaluateJavaScript("document.getElementById('contents').click(); document.getElementById('tab-notes').click(); document.querySelector('.edit-note').click(); document.getElementById('note-text').value='Native draft preserved'; true")
    }
    func testDraftPrompt() async throws -> Bool {
        try await webView.evaluateJavaScript("document.getElementById('draft-panel').open") as? Bool ?? false
    }
    func testChooseDraft(_ id: String) async throws {
        _ = try await webView.evaluateJavaScript("document.getElementById('\(id)').click(); true")
    }
    func testAddDurableNote() async throws {
        _ = try await webView.evaluateJavaScript("window.StillleafReader.addBookmark(); window.StillleafReader.annotate({locator:window.StillleafReader.bookmark(),quote:'Synthetic passage',note:'N'.repeat(65536),color:'gold'}); true")
    }
    func testNoteLength() async throws -> Int {
        try await webView.evaluateJavaScript("window.StillleafReader.exportState().annotations.at(-1)?.note.length || 0") as? Int ?? 0
    }
    func flushStateForTest() { stateWorker.sync {} }
    func testDiagnostic() async throws -> String {
        let result = try await webView.evaluateJavaScript("JSON.stringify({url:location.href,api:typeof window.StillleafReader,frames:document.querySelectorAll('iframe').length,text:document.body?.innerText})")
        return (result as? String ?? "") + " startup=" + (startupError ?? "none") + " didLoad=\(didLoad)"
    }
    func testContent() async throws -> String {
        let result = try await webView.evaluateJavaScript("Array.from(document.querySelectorAll('iframe')).map(f => f.contentDocument?.body?.innerText || '').join('').trim()")
        return result as? String ?? ""
    }
    func testHref() async throws -> String {
        let result = try await webView.evaluateJavaScript("window.StillleafReader?.bookmark()?.href || ''")
        return result as? String ?? ""
    }
}

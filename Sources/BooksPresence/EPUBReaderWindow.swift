import AppKit
import Combine
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
    var positionChanged: (() -> Void)?
    var positionFinalized: ((ProgressObservation) -> Void)?
    var libraryRequested: (() -> Void)?
    var traversedContent: ((String, PageTurnEvidence) -> Void)?
    private let stateDirectory: URL
    private var focusedReader: EPUBReaderWindow? {
        guard NSApp.isActive else { return nil }
        return windows.values.first(where: { $0.isReady && $0.window?.isKeyWindow == true && $0.window?.isMiniaturized == false })
    }
    private var commandReader: EPUBReaderWindow? {
        guard NSApp.isActive, !isTerminating else { return nil }
        return windows.values.first { $0.isReady && $0.chrome?.canAcceptCommands == true && ($0.window?.isKeyWindow == true || $0.chrome?.owns(NSApp.keyWindow) == true) }
    }
    var hasCommandReader: Bool { commandReader != nil }
    func performControl(_ command: String) {
        guard let owner = commandReader else { return }
        if command == "appearance" { owner.chrome.openAppearance() }
        else { owner.chrome.command(command) }
    }
    var focusedPublicationID: String? { focusedReader?.publication.id }
    var focusedProgress: ProgressObservation? { focusedReader?.progress }
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
        reader.positionChanged = { [weak self, weak reader] in
            guard let self, let reader else { return }
            self.deliverPosition(from: reader)
        }
        reader.positionFinalized = { [weak self] progress in self?.positionFinalized?(progress) }
        reader.traversedContent = { [weak self, weak reader] evidence in
            guard let self, let reader, self.focusedReader === reader else { return }
            self.traversedContent?("epub:" + publication.id, evidence)
        }
        reader.focused = { [weak self] in self?.didFocusReader?() }
        reader.returnToLibrary = { [weak self] in self?.libraryRequested?() }
        windows[publication.id] = reader
        if present { reader.show() }
        else { reader.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); reader.window?.orderBack(nil) }
    }
    fileprivate func deliverPosition(from reader: EPUBReaderWindow) {
        if focusedReader === reader { positionChanged?() }
        else if let progress = reader.progress {
            // A debounced renderer report can arrive after resign-key already flushed.
            // Keep that final location without treating the background report as activity.
            positionFinalized?(progress)
        }
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
    fileprivate var chrome: NativeReaderChrome!
    private var chromeRequest: UInt64 = 0
    private var chromeGeneration: UInt64 = 0
    private var lastChromeSequence: UInt64 = 0
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
    private var lastSequence: UInt64 = 0
    private(set) var nativePosition: NativeReaderPosition?
    private(set) var progress: ProgressObservation?
    var traversedContent: ((PageTurnEvidence) -> Void)?
    var positionChanged: (() -> Void)?
    private var progressDelivery = ReaderProgressDeliveryGate()
    private var progressDeliveryTask: Task<Void, Never>?
    private var gardenSubscription: AnyCancellable?

    /// Passes the app's Garden setting to the margin garden, now and whenever it changes.
    private func sendGardenMode() {
        if gardenSubscription == nil {
            gardenSubscription = ThemeStore.shared.$revision.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.sendGardenMode() }
        }
        guard isReady else { return }
        let mode = ThemeStore.shared.effectiveGardenMode(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion).rawValue
        webView.callAsyncJavaScript("window.StillleafReader.setGardenMode?.(mode)", arguments: ["mode": mode], in: nil, in: .page) { _ in }
    }
    var positionFinalized: ((ProgressObservation) -> Void)?

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
        window.title = publication.title; window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 520, height: 440)
        // Menu-bar (accessory) apps get no full-screen behavior unless a window opts in.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = webView; window.isReleasedWhenClosed = false
        window.delegate = self; window.center(); self.window = window
        chrome = NativeReaderChrome(window: window)
        chrome.send = { [weak self] command, payload in
            guard let self else { throw ReaderStateValidation.Failure.invalidState }
            return try await self.sendNativeControl(command, payload: payload)
        }
        chrome.returnFocus = { [weak self] in guard let self, !self.closing else { return }; self.window?.makeFirstResponder(self.webView) }
        webView.load(URLRequest(url: map.url(for: "index.html")!))
    }

    func show() { AppPresence.willPresentWindow(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowDidBecomeKey(_ notification: Notification) { focused?() }
    func windowDidResignKey(_ notification: Notification) { flushPositionUpdate(final: true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { await requestClose() }
        return false
    }
    func requestClose() async -> Bool {
        guard !closing else { return false }
        closing = true
        chrome?.setClosing(true)
        defer { closing = false; chrome?.setClosing(false); window?.ignoresMouseEvents = false }
        do {
            try await chrome?.flush()
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
            flushPositionUpdate(final: true)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Your latest reading changes could not be saved"
            alert.informativeText = "Keep this window open to retain the current notes and reading position, or close without saving the latest changes. \(error.localizedDescription)"
            alert.addButton(withTitle: "Keep open")
            alert.addButton(withTitle: "Close without saving")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        chromeGeneration += 1; chrome?.disconnect()
        window?.close()
        return true
    }
    func windowWillClose(_ notification: Notification) {
        chromeGeneration += 1; chrome?.disconnect()
        flushPositionUpdate(final: true)
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
        if event["type"] as? String == "ready" { isReady = true; sendGardenMode(); if window?.isKeyWindow == true { focused?() }; Task { await chrome.connect() }; return }
        if event["type"] as? String == "chrome-focus" { chrome.returnFocus?(); return }
        if event["type"] as? String == "chrome" {
            guard event["version"] as? Int == 1, let sequence = event["sequence"] as? NSNumber,
                  sequence.doubleValue.isFinite, sequence.doubleValue > 0, sequence.doubleValue <= 9_007_199_254_740_991,
                  sequence.doubleValue.rounded() == sequence.doubleValue, sequence.uint64Value > lastChromeSequence else { return }
            lastChromeSequence = sequence.uint64Value; chrome.accept(event); return
        }
        if event["type"] as? String == "error" { isReady = false; return }
        if event["type"] as? String == "position" || event["type"] as? String == "pageTurn" {
            receiveProgress(event); return
        }
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

    private func sendNativeControl(_ command: String, payload: [String: Any]?) async throws -> [String: Any] {
        // Chrome blocks new interactions at close entry. Its already-queued
        // preference batch and Reset must drain before exporting durable state.
        guard isReady, !closing || command == "preferences" || command == "reset" || command == "deactivate" else { throw ReaderStateValidation.Failure.invalidState }
        chromeRequest += 1
        let request = chromeRequest, generation = chromeGeneration
        var envelope: [String: Any] = ["version": 1, "editionId": publication.id, "id": request, "command": command]
        if let payload { envelope["payload"] = payload }
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled, !finished else { return }
                finished = true; continuation.resume(throwing: ReaderStateValidation.Failure.invalidState)
            }
            webView.callAsyncJavaScript("return await window.StillleafReader.nativeControl(request)", arguments: ["request": envelope], in: nil, in: .page) { result in
                Task { @MainActor in
                    guard !finished else { return }; finished = true; timeout.cancel(); continuation.resume(with: result)
                }
            }
        }
        guard generation == chromeGeneration, let response = value as? [String: Any],
              (response["requestId"] as? NSNumber)?.uint64Value == request,
              response["editionId"] as? String == publication.id else { throw ReaderStateValidation.Failure.invalidState }
        return response
    }

    /// The authenticated renderer supplies actual chapter geometry and text ranges.
    /// Sequence numbers reject replay; only foreground sequential turns add coverage.
    private func receiveProgress(_ event: [String: Any]) {
        guard let observed = event["observedAt"] as? Double, observed.isFinite,
              (-1...3).contains(Date().timeIntervalSince1970 - observed / 1000),
              let number = event["sequence"] as? NSNumber,
              number.doubleValue > 0, number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded() == number.doubleValue,
              number.uint64Value > lastSequence else { return }
        lastSequence = number.uint64Value
        let key = event["type"] as? String == "position" ? "position" : "departure"
        guard let value = event[key] as? [String: Any], JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let position = try? JSONDecoder().decode(NativeReaderPosition.self, from: data),
              position.isValid(spine: publication.spine) else { return }
        if key == "position" {
            let previous = progress?.location
            let previousFraction = progress?.fraction
            nativePosition = position
            progress = position.observation(bookID: "epub:" + publication.id, spine: publication.spine)
            if progress?.location != previous || progress?.fraction != previousFraction { schedulePositionUpdate() }
        } else if isReady, NSApp.isActive, window?.isKeyWindow == true,
                  event["direction"] as? String == "forward",
                  let evidence = position.forwardCoverage(spine: publication.spine) {
            traversedContent?(evidence)
        }
    }

    // Keep nativePosition/progress current for the ordinary one-second tracking poll,
    // but do not run synchronous tracking/database/history work for every scroll line.
    // Page-turn coverage remains immediate and independent of this notification gate.
    private func schedulePositionUpdate() {
        let delay = progressDelivery.request(at: ProcessInfo.processInfo.systemUptime)
        if delay == 0 { flushPositionUpdate(); return }
        guard progressDeliveryTask == nil else { return }
        progressDeliveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            self?.flushPositionUpdate()
        }
    }

    private func flushPositionUpdate(final: Bool = false) {
        progressDeliveryTask?.cancel()
        progressDeliveryTask = nil
        if progressDelivery.deliver(at: ProcessInfo.processInfo.systemUptime) {
            if final, let progress { positionFinalized?(progress) }
            else { positionChanged?() }
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
            // Continuous reads as one scroll across chapters; without this, scroll mode stops at each chapter end.
            "experimentalContinuous": true, "contentProgress": true,
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

/// Flush fixture progress independently of buffered stdout, including before a stuck WebKit await.
private func readerSmokeCheckpoint(_ phase: String) {
    FileHandle.standardError.write(Data("epub-reader-smoke-stage: \(phase)\n".utf8))
}

/// Fixture-only CLI check. Never uses the app's production store or preferences.
@MainActor
func runEPUBReaderSmoke(fixture: URL) async throws {
    readerSmokeCheckpoint("native command queue")
    try await runNativeReaderQueueSmoke()
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-reader-smoke-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let importer = EPUBPublicationImporter(directory: temporary.appendingPathComponent("Publications"))
    readerSmokeCheckpoint("fixture import")
    let imported = try await Task.detached { try importer.importPublication(from: fixture) }.value
    let defaultsName = "Stillleaf.reader-smoke." + UUID().uuidString
    let defaults = UserDefaults(suiteName: defaultsName)!
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let model = try AppModel(support: temporary, defaults: defaults, startTracking: false)
    var presentations = 0
    model.dashboardAction = { presentations += 1 }
    readerSmokeCheckpoint("library import and duplicate handling")
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
    for terminating in [false, true] {
        readerSmokeCheckpoint(terminating ? "queued reset during quit" : "queued reset during close")
        let raceState = temporary.appendingPathComponent(terminating ? "QueuedResetQuit" : "QueuedResetClose")
        let raceReader = try await EPUBReaderWindow(publication: imported.publication, directory: imported.directory, stateDirectory: raceState)
        raceReader.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); raceReader.window?.orderBack(nil)
        try await raceReader.testWaitUntilReady()
        try await raceReader.testCloseWithQueuedReset(terminating: terminating, stateDirectory: raceState)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: raceState.appendingPathComponent(imported.publication.id + ".json"))) as? [String: Any]
        guard (saved?["preferences"] as? [String: Any])?["fontSize"] as? Double == 1.2 else {
            throw EPUBImportError.invalid("Close/Quit did not durably save queued Reset.")
        }
    }
    readerSmokeCheckpoint("activation during failed close")
    let activationState = temporary.appendingPathComponent("ActivationCloseKeepOpen")
    let activationReader = try await EPUBReaderWindow(publication: imported.publication, directory: imported.directory, stateDirectory: activationState)
    activationReader.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); activationReader.window?.orderBack(nil)
    try await activationReader.testWaitUntilReady()
    try await activationReader.testActivationDuringFailedClose(stateDirectory: activationState)
    readerSmokeCheckpoint("main reader creation")
    let state = temporary.appendingPathComponent("ReaderState")
    let reader = try await EPUBReaderWindow(publication: imported.publication, directory: imported.directory, stateDirectory: state)
    defer { reader.window?.close() }
    guard reader.window?.collectionBehavior.contains(.fullScreenPrimary) == true else {
        throw EPUBImportError.invalid("Reader window cannot enter full screen.")
    }
    reader.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    reader.window?.orderBack(nil)
    readerSmokeCheckpoint("initial chapter render")
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
    readerSmokeCheckpoint("fixture assets")
    guard try await reader.testFixtureAssets() else {
        throw EPUBImportError.invalid("Chapter stylesheet or image did not load through the reader scheme.")
    }
    readerSmokeCheckpoint("native controls")
    try await reader.testNativeChrome()
    readerSmokeCheckpoint("render stability")
    try await reader.testRenderStability()
    readerSmokeCheckpoint("page evidence")
    try await reader.testPageEvidence()
    try reader.testProgressDeliveryBurst()
    if let index = CommandLine.arguments.firstIndex(of: "--reader-artifacts"), index + 1 < CommandLine.arguments.count {
        readerSmokeCheckpoint("review snapshots")
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
    readerSmokeCheckpoint("durable note")
    try await reader.testAddDurableNote()
    readerSmokeCheckpoint("reading modes")
    var expectedPreferences = try await reader.testReadingModes()
    if CommandLine.arguments.contains("--reader-appearance-review") {
        guard let index = CommandLine.arguments.firstIndex(of: "--reader-artifacts"), index + 1 < CommandLine.arguments.count else { throw EPUBImportError.invalid("Appearance proof needs an artifact directory.") }
        readerSmokeCheckpoint("appearance scenarios")
        try await reader.testAppearanceReview(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        expectedPreferences = try await reader.testPreferences()
    }
    readerSmokeCheckpoint("garden mode")
    let expectedGarden = ThemeStore.shared.effectiveGardenMode(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion).rawValue
    guard try await reader.testGardenMode() == expectedGarden else { throw EPUBImportError.invalid("Reader did not receive the Garden setting.") }
    readerSmokeCheckpoint("durable close")
    guard await reader.requestClose() else { throw EPUBImportError.invalid("Reader close did not complete.") }
    let closedState = try JSONSerialization.jsonObject(with: Data(contentsOf: locationURL)) as? [String: Any]
    guard let notes = closedState?["annotations"] as? [[String: Any]],
          notes.last?["note"] as? String == String(repeating: "N", count: 65_536),
          (closedState?["bookmarks"] as? [Any])?.count == 1 else {
        throw EPUBImportError.invalid("Immediate close lost the latest note or bookmark.")
    }
    readerSmokeCheckpoint("restore saved reader")
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
    readerSmokeCheckpoint("failed draft save and cancelled quit")
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
    readerSmokeCheckpoint("recovered draft save")
    try await second.testRestoreDraftSaving()
    let savedClose = Task { await manager.closeAll() }
    guard await savedClose.value else { throw EPUBImportError.invalid("Autosaving the recovered draft did not complete native close.") }
    let draftSaved = try JSONSerialization.jsonObject(with: Data(contentsOf: locationURL)) as? [String: Any]
    guard (draftSaved?["annotations"] as? [[String: Any]])?.last?["note"] as? String == "Native draft preserved" else {
        throw EPUBImportError.invalid("Native close did not durably save the note draft.")
    }
    readerSmokeCheckpoint("optional continuous proof")
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
    print("epub-reader-smoke: Library-first import, scoped rendering, three reading modes, narrow fallback, long-note/bookmark/preferences reopen, native failed-save draft cancel and autosaved durable close passed (synthetic; no activity credit)")
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
    func testProgressDeliveryBurst() throws {
        guard let href = publication.spine.first else { throw EPUBImportError.invalid("Missing smoke-test spine.") }
        flushPositionUpdate()
        let priorCallback = positionChanged, priorGate = progressDelivery, priorFinalized = positionFinalized
        let priorPosition = nativePosition, priorProgress = progress, priorSequence = lastSequence
        var deliveries = 0
        var finalized: [ProgressObservation] = []
        positionChanged = { deliveries += 1 }
        positionFinalized = { finalized.append($0) }
        progressDelivery = ReaderProgressDeliveryGate()
        defer {
            progressDeliveryTask?.cancel(); progressDeliveryTask = nil
            positionChanged = priorCallback; progressDelivery = priorGate; positionFinalized = priorFinalized
            nativePosition = priorPosition; progress = priorProgress; lastSequence = priorSequence
        }
        for offset in 1...120 {
            receiveProgress(["type": "position", "observedAt": Date().timeIntervalSince1970 * 1000,
                "sequence": NSNumber(value: priorSequence + UInt64(offset)),
                "position": ["href": href, "page": 1, "totalPages": 10, "visiblePages": 1,
                             "bookOffset": offset, "bookTotal": 1000]])
        }
        guard deliveries == 1, nativePosition?.bookOffset == 120,
              progress?.fraction == 0.12, progressDelivery.pending else {
            throw EPUBImportError.invalid("Native burst did not retain the newest position with bounded tracking notifications.")
        }
        windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        flushPositionUpdate(final: true)
        guard deliveries == 1, finalized.count == 1, finalized.first?.fraction == 0.12,
              !progressDelivery.pending, progressDeliveryTask == nil else {
            throw EPUBImportError.invalid("Native focus-loss/close flush did not deliver pending progress exactly once.")
        }
        let manager = EPUBReaderWindows(stateDirectory: stateURL.deletingLastPathComponent())
        manager.positionChanged = { deliveries += 1 }
        manager.positionFinalized = { finalized.append($0) }
        positionChanged = { [unowned self] in manager.deliverPosition(from: self) }
        receiveProgress(["type": "position", "observedAt": Date().timeIntervalSince1970 * 1000,
            "sequence": NSNumber(value: priorSequence + 121),
            "position": ["href": href, "page": 1, "totalPages": 10, "visiblePages": 1,
                         "bookOffset": 121, "bookTotal": 1000]])
        // Exercise the ordinary trailing task's path after focus has already gone.
        flushPositionUpdate()
        flushPositionUpdate(final: true)
        guard deliveries == 1, finalized.count == 2, finalized.last?.fraction == 0.121,
              !progressDelivery.pending, progressDeliveryTask == nil else {
            throw EPUBImportError.invalid("A late background position was dropped or incorrectly counted as activity.")
        }
        print("reader-progress-burst: 120 positions coalesced; focus-loss and late background final positions retained once without activity")
    }

    func testNativeChrome() async throws {
        let deadline = Date().addingTimeInterval(15)
        while !chrome.isConnected && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard chrome.isConnected, window?.toolbar === chrome.toolbar else { throw EPUBImportError.invalid("Native toolbar handshake did not finish") }
        guard chrome.model.definitions.count == chrome.model.preferences.count else { throw EPUBImportError.invalid("Native appearance omits a preference") }
        try await chrome.testPendingFeedback()
        let before = try await webView.evaluateJavaScript("JSON.stringify(window.StillleafReader.exportState())") as? String ?? ""
        try chrome.testClick("bookmark")
        let bookmarkDeadline = Date().addingTimeInterval(3)
        while Date() < bookmarkDeadline {
            if let count = try await webView.evaluateJavaScript("window.StillleafReader.exportState().bookmarks.length") as? Int, count > 0 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard let count = try await webView.evaluateJavaScript("window.StillleafReader.exportState().bookmarks.length") as? Int, count > 0 else { throw EPUBImportError.invalid("Actual native bookmark button did not dispatch") }
        try chrome.testClick("bookmark")
        let restoreDeadline = Date().addingTimeInterval(3)
        while Date() < restoreDeadline {
            if let count = try await webView.evaluateJavaScript("window.StillleafReader.exportState().bookmarks.length") as? Int, count == 0 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        if CommandLine.arguments.contains("--reader-artifacts") && BackgroundUI.isEnabled {
            // Popovers only open in an active app, and background runs never activate.
            print("native-reader-chrome: active toolbar and appearance-popover captures SKIPPED in background mode; CI runs them, or set STILLLEAF_FOREGROUND_UI=1 when nobody is using the Mac")
        } else if let index = CommandLine.arguments.firstIndex(of: "--reader-artifacts"), index + 1 < CommandLine.arguments.count, let window {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            show() // Match the normal reader presentation path for active chrome captures.
            try await captureNativeWindow(window, to: directory.appendingPathComponent("native-reader-toolbar.png"))
            print("native-reader-capture-focus: appActive=\(NSApp.isActive) key=\(window.isKeyWindow)")
            try await chrome.testCaptureAppearance(to: directory.appendingPathComponent("native-reader-appearance.png"))
            try await chrome.benchmarkFeedback(output: directory.appendingPathComponent("native-feedback.json"))
            let originalFrame = window.frame, originalAppearance = window.appearance, originalPreferences = chrome.model.preferences
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setFrame(NSRect(origin: originalFrame.origin, size: NSSize(width: 520, height: 440)), display: true)
                _ = try await sendNativeControl("preferences", payload: ["theme": dark ? "dark" : "paper"])
                let prefix = dark ? "native-compact-dark" : "native-compact-light"
                try await captureNativeWindow(window, to: directory.appendingPathComponent(prefix + "-toolbar.png"))
                try await chrome.testCaptureAppearance(to: directory.appendingPathComponent(prefix + "-appearance.png"), includeBottom: true)
            }
            window.appearance = originalAppearance; window.setFrame(originalFrame, display: true)
            _ = try await sendNativeControl("preferences", payload: originalPreferences)
        }
        guard before.contains("schemaVersion") else { throw EPUBImportError.invalid("Missing canonical state") }
        print("native-reader-chrome: actual AppKit toolbar, complete appearance definitions and durable renderer dispatch passed")
    }
    func testCloseWithQueuedReset(terminating: Bool, stateDirectory: URL) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !chrome.isConnected && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard chrome.isConnected, let originalSend = chrome.send else { throw EPUBImportError.invalid("Queued Reset test requires connected chrome.") }
        var release: CheckedContinuation<Void, Never>?
        chrome.send = { command, payload in
            if command == "preferences" { await withCheckedContinuation { release = $0 } }
            return try await originalSend(command, payload)
        }
        defer { chrome.send = originalSend; release?.resume() }
        chrome.model.change?("fontSize", 1.8)
        let batchDeadline = Date().addingTimeInterval(3)
        while release == nil && Date() < batchDeadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard release != nil else { throw EPUBImportError.invalid("Appearance batch did not reach delayed transport.") }
        chrome.model.reset?()
        let manager = EPUBReaderWindows(stateDirectory: stateDirectory)
        if terminating { manager.testAdopt(self) }
        // Fail this synthetic regression rather than leave CI in a modal alert
        // if draining unexpectedly fails. Production alerts remain unchanged.
        let modalWatch = Task { @MainActor in
            while !Task.isCancelled {
                if NSApp.modalWindow != nil { NSApp.abortModal(); return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        defer { modalWatch.cancel() }
        let close = Task { @MainActor in terminating ? await manager.closeAll() : await requestClose() }
        let closeDeadline = Date().addingTimeInterval(3)
        while !closing && Date() < closeDeadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard closing, !chrome.canAcceptCommands else { throw EPUBImportError.invalid("Close did not block new native interactions.") }
        chrome.model.change?("fontSize", 2.7); chrome.model.reset?()
        release?.resume(); release = nil
        guard await close.value, chrome.model.preferences["fontSize"] as? Double == 1.2 else {
            throw EPUBImportError.invalid("Queued Reset failed while closing or terminating.")
        }
        print("native-reader-queue: delayed batch + queued Reset + \(terminating ? "Quit" : "Close") durably drained; new interactions blocked")
    }
    func testActivationDuringFailedClose(stateDirectory: URL) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !chrome.isConnected && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard chrome.isConnected, let originalSend = chrome.send else { throw EPUBImportError.invalid("Activation recovery test requires connected chrome.") }
        chrome.disconnect()
        _ = try await originalSend("deactivate", nil)
        var release: CheckedContinuation<Void, Never>?
        chrome.send = { command, payload in
            let value = try await originalSend(command, payload)
            if command == "activate" { await withCheckedContinuation { release = $0 } }
            return value
        }
        defer { chrome.send = originalSend; release?.resume() }
        let connect = Task { @MainActor in await chrome.connect() }
        let activationDeadline = Date().addingTimeInterval(5)
        while release == nil && Date() < activationDeadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard release != nil else { throw EPUBImportError.invalid("Activation did not reach delayed acknowledgement.") }
        // Temporary fixture only: block the real durable-save worker, then make
        // its directory unwritable by replacing it with a file. No mock close.
        stateWorker.sync {}
        let backup = stateDirectory.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: stateDirectory, to: backup)
        try Data("synthetic save failure".utf8).write(to: stateDirectory)
        let saveGate = DispatchSemaphore(value: 0)
        stateWorker.async { saveGate.wait() }
        var gateReleased = false, restoredDirectory = false
        defer {
            if !gateReleased { saveGate.signal() }
            if !restoredDirectory {
                try? FileManager.default.removeItem(at: stateDirectory)
                try? FileManager.default.moveItem(at: backup, to: stateDirectory)
            }
        }
        var keptOpen = false
        let keepOpen = Timer(timeInterval: 0.01, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow != nil else { return }
                keptOpen = true; NSApp.stopModal(withCode: .alertFirstButtonReturn); timer.invalidate()
            }
        }
        RunLoop.main.add(keepOpen, forMode: .modalPanel)
        defer { keepOpen.invalidate() }
        let close = Task { @MainActor in await requestClose() }
        let closeDeadline = Date().addingTimeInterval(3)
        while !closing && Date() < closeDeadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard closing else { throw EPUBImportError.invalid("Close did not reach save drain.") }
        release?.resume(); release = nil
        await connect.value
        saveGate.signal(); gateReleased = true
        guard !(await close.value), keptOpen, !closing, !chrome.isConnected, !chrome.toolbar.isVisible,
              try await webView.evaluateJavaScript("getComputedStyle(document.querySelector('.reader-bar')).display !== 'none'") as? Bool == true else {
            throw EPUBImportError.invalid("Failed close stranded reader controls after delayed activation.")
        }
        try FileManager.default.removeItem(at: stateDirectory)
        try FileManager.default.moveItem(at: backup, to: stateDirectory)
        restoredDirectory = true
        guard await requestClose() else { throw EPUBImportError.invalid("Recovered reader did not close durably.") }
        print("native-reader-activation: delayed response during real save failure + Keep Open restored exactly one usable web surface")
    }
    func testGardenMode() async throws -> String {
        let deadline = Date().addingTimeInterval(3)
        var mode = ""
        repeat {
            mode = try await webView.evaluateJavaScript("document.documentElement.dataset.garden ?? ''") as? String ?? ""
            if !mode.isEmpty { return mode }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        return mode
    }

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
        require(flow.scrollTop>outerBefore&&frames().every(f=>f.contentDocument.scrollingElement.scrollTop===0),'keyboard did not scroll outer surface exclusively'+JSON.stringify({outerBefore,after:flow.scrollTop,max:flow.scrollHeight-flow.clientHeight,inner:frames().map(f=>f.contentDocument.scrollingElement.scrollTop)}));
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
    /// Synthetic fixture only: real WKWebView must preserve XHTML targets and the
    /// exact page geometry when the animation overlay reveals its live document.
    func testRenderStability() async throws {
        let script = """
        const api=window.StillleafReader;
        const frame=()=>[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden'&&f.contentDocument?.body);
        if(!frame()?.contentDocument.getElementById('fixture-page'))return 'fixture markers absent';
        const saved=api.exportState(),pause=ms=>new Promise(r=>setTimeout(r,ms));
        const require=(ok,message)=>{if(!ok)throw Error(message)};
        await api.setPreferences({theme:'original',fontFamily:'sans',fontSize:1.3,scroll:false,columns:'one'});
        await api.go({href:saved.position.href,type:'text/html',locations:{progression:0}});
        let f=frame(),d=f.contentDocument,p=d.getElementById('fixture-prose');
        require(!p.closest('a')&&d.getElementById('fixture-page').textContent==='', 'XHTML destination swallowed prose');
        require(f.contentWindow.getComputedStyle(p).color===f.contentWindow.getComputedStyle(d.body).color, 'Publisher link style colored prose');
        require(d.querySelector('a[href*="#note-one"]'), 'Footnote link was lost');
        if(matchMedia('(prefers-reduced-motion: reduce)').matches){await api.setPreferences(saved.preferences);await api.go(saved.position);return 'anchor checks passed; slide skipped for Reduced Motion'};
        const turn=api.next();let animation;
        const deadline=performance.now()+5000;
        while(performance.now()<deadline){animation=document.querySelector('.page-slide-track')?.getAnimations().find(a=>a.playState==='running');if(animation)break;await pause(10)}
        require(animation,'No page-slide animation for fixture');
        animation.pause();animation.currentTime=animation.effect.getTiming().duration;
        await new Promise(requestAnimationFrame);
        const copy=[...document.querySelectorAll('.page-slide-snapshot')].at(-1);f=frame();
        const geometry=frame=>{const d=frame.contentDocument,r=frame.getBoundingClientRect();return {mode:d.compatMode,host:[r.x,r.y],rects:[...d.querySelectorAll('h1,p')].map(p=>{const r=p.getBoundingClientRect();return [r.x,r.y,r.width,r.height]})}};
        const live=geometry(f),snapshot=geometry(copy);
        require(live.mode===snapshot.mode&&live.mode==='CSS1Compat','Snapshot document mode differs');
        require(live.host.every((v,i)=>Math.abs(v-snapshot.host[i])<1),'Snapshot frame position differs');
        require(live.rects.length===snapshot.rects.length&&live.rects.every((r,i)=>r.every((v,j)=>Math.abs(v-snapshot.rects[i][j])<1)),'Snapshot text geometry differs');
        animation.finish();await turn;await pause(100);
        const revealed=geometry(frame());
        require(live.rects.every((r,i)=>r.every((v,j)=>Math.abs(v-revealed.rects[i][j])<1)),'Text moved after animation');
        await api.setPreferences(saved.preferences);await api.go(saved.position);
        return 'XHTML anchor styling and snapshot/live text geometry passed';
        """
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in continuation.resume(with: result) }
        }
        print("epub-reader-render-stability: " + String(describing: result))
    }
    /// A deliberate turn must reach the host as actual chapter geometry.
    func testPageEvidence() async throws {
        let deadline = Date().addingTimeInterval(5)
        while nativePosition == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard let before = nativePosition else { throw EPUBImportError.invalid("The reader never announced its page layout.") }
        _ = try await webView.evaluateJavaScript("window.StillleafReader.next(); true")
        while (nativePosition?.page ?? 0) <= before.page && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard let after = nativePosition, after.page == before.page + before.visiblePages,
              after.href == before.href else {
            throw EPUBImportError.invalid("A page turn did not reach the host chapter position: \(String(describing: nativePosition))")
        }
        _ = try await webView.evaluateJavaScript("window.StillleafReader.previous(); true")
        // Later checks read the chapter href, so wait for the turn back to land.
        let backDeadline = Date().addingTimeInterval(5)
        while nativePosition?.page != before.page && Date() < backDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard nativePosition?.page == before.page else {
            throw EPUBImportError.invalid("Turning back did not return to the starting page: \(String(describing: nativePosition))")
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
    func testAppearanceReview(directory: URL) async throws {
        // Fixture-only narrow stress size; production keeps its 520-point minimum.
        window?.minSize = NSSize(width: 390, height: 440)
        let prepare = """
        const api=window.StillleafReader,book=JSON.parse(payload);book.state=api.exportState();book.experimentalContinuous=true;
        await api.open(book);
        window.appearanceBaseline={notes:JSON.stringify(api.exportState().annotations),bookmarks:JSON.stringify(api.exportState().bookmarks)};
        window.appearanceTarget={href:book.readingOrder[0].href,type:'text/html',locations:{cssSelector:'body > p:nth-of-type(2)'},text:{highlight:'She had meant to read only a few pages.'}};
        await api.go(window.appearanceTarget);return true;
        """
        readerSmokeCheckpoint("appearance fixture preparation")
        let _: Any = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(prepare, arguments: ["payload": payload], in: nil, in: .page) { result in continuation.resume(with: result) }
        }
        var records: [[String: Any]] = []
        let scenarios: [(String, Int, Int, String, String, Bool, String, Double, Bool, Bool)] = [
            ("appearance-literata", 1280, 900, "literata", "paper", false, "one", 1.2, false, false),
            ("appearance-lora-wide", 1400, 900, "lora", "sepia", false, "one", 1.2, false, true),
            ("appearance-atkinson-facing", 1400, 900, "atkinson", "white", false, "two", 1.2, false, true),
            ("appearance-night", 1400, 900, "literata", "midnight", false, "two", 1.2, false, true),
            ("appearance-custom-continuous", 1400, 900, "lora", "custom", true, "one", 1.2, false, true),
            ("appearance-narrow520-large", 520, 800, "atkinson", "midnight", false, "one", 3.0, false, true),
            ("appearance-narrow390-large", 390, 800, "atkinson", "paper", true, "one", 3.0, false, true),
            ("appearance-focus", 1400, 900, "literata", "midnight", false, "one", 1.5, true, true)
        ]
        for (name, width, height, font, theme, scroll, columns, scale, immersive, wide) in scenarios {
            readerSmokeCheckpoint("\(name): layout and fonts")
            window?.setContentSize(NSSize(width: width, height: height))
            try await Task.sleep(nanoseconds: 400_000_000)
            let script = """
            const api=window.StillleafReader;
            await api.setPreferences({fontFamily:font,theme,scroll,columns,fontSize:scale,immersive,contentWidth:wide?100:90,measure:wide?110:65,sideMargin:wide?8:32,lineHeight:1.6,fontWeight:null,textAlign:'publisher',letterSpacing:0,wordSpacing:0,backgroundColor:'#162530',textColor:'#F2E6CB'});
            await new Promise(r=>setTimeout(r,400));
            const frames=[...document.querySelectorAll('#reader iframe')].filter(f=>getComputedStyle(f).visibility!=='hidden'&&f.contentDocument?.body);
            const family={literata:'Stillleaf Literata',lora:'Stillleaf Lora',atkinson:'Stillleaf Atkinson Hyperlegible'}[font];
            const metrics=[];
            for(const f of frames){
              const d=f.contentDocument,w=f.contentWindow,b=d.body,p=d.querySelector('p'),e=d.scrollingElement;
              const loaded=await d.fonts.load('400 18px "'+family+'"');await d.fonts.ready;
              const faces=[...d.fonts].filter(face=>face.family.replace(/['"]/g,'')===family).map(face=>({family:face.family,status:face.status,weight:face.weight,style:face.style}));
              const rect=f.getBoundingClientRect(),style=w.getComputedStyle(p),before=b.getBoundingClientRect().top;
              const sample=d.createElement('span');sample.textContent='Hamburgefontsiv 0123456789 Wide margins and little leaves';sample.style.cssText='position:absolute;white-space:nowrap;font-size:20px;font-weight:400;font-style:normal;letter-spacing:0;word-spacing:0';p.append(sample);
              sample.style.setProperty('font-family',style.fontFamily,'important');const actualWidth=sample.getBoundingClientRect().width;sample.style.setProperty('font-family','"'+family+'"','important');const desiredWidth=sample.getBoundingClientRect().width;sample.style.setProperty('font-family','serif','important');const fallbackWidth=sample.getBoundingClientRect().width;sample.remove();
              const renderedFont={actualWidth,desiredWidth,fallbackWidth,matches:Math.abs(actualWidth-desiredWidth)<.5&&Math.abs(desiredWidth-fallbackWidth)>1};
              let probe=null;if(scroll){e.scrollTop=100;probe={top:e.scrollTop,movement:b.getBoundingClientRect().top-before};e.scrollTop=0}
              const target=d.querySelector('body > p:nth-of-type(2)'),range=d.createRange();range.setStart(target.firstChild,0);range.setEnd(target.firstChild,Math.min(12,target.firstChild.length));
              const targetRects=[...range.getClientRects()].map(r=>({top:r.top,bottom:r.bottom,left:r.left,right:r.right}));
              metrics.push({family:style.fontFamily,faces,renderedFont,loaded:loaded.length,color:style.color,background:w.getComputedStyle(b).backgroundColor,fontSize:style.fontSize,zoom:w.getComputedStyle(b).zoom,width:f.clientWidth,height:f.clientHeight,left:rect.left,right:rect.right,rootWidth:e.scrollWidth,rootHeight:e.scrollHeight,probe,renderedBottom:Math.max(b.getBoundingClientRect().bottom,...[...b.querySelectorAll('*')].map(x=>x.getBoundingClientRect().bottom)),renderedRight:Math.max(b.getBoundingClientRect().right,...[...b.querySelectorAll('*')].map(x=>x.getBoundingClientRect().right)),targetRects});
            }
            const saved=api.exportState(),flow=document.querySelector('#reader'),bounds=flow.getBoundingClientRect();
            const retained=saved.position?.href===window.appearanceTarget.href&&JSON.stringify(saved.annotations)===window.appearanceBaseline.notes&&JSON.stringify(saved.bookmarks)===window.appearanceBaseline.bookmarks;
            const targetVisible=frames.some((f,i)=>metrics[i].targetRects.some(r=>{const v=f.getBoundingClientRect();return r.bottom+v.top>bounds.top&&r.top+v.top<bounds.bottom&&r.right>0&&r.left<f.clientWidth}));
            return JSON.stringify({name,width:innerWidth,height:innerHeight,preferences:saved.preferences,retained,targetVisible,fontsLoaded:metrics.length>0&&metrics.every(m=>m.loaded>0&&m.renderedFont.matches&&m.family.includes(family)&&m.faces.some(f=>f.status==='loaded')),outerOverflow:document.documentElement.scrollWidth>innerWidth+1,immersiveActive:document.documentElement.classList.contains('immersive'),returnControlVisible:!document.querySelector('#leave-focus').hidden,readerWidth:bounds.width,frames:metrics});
            """
            let output: Any = try await withCheckedThrowingContinuation { continuation in
                webView.callAsyncJavaScript(script, arguments: ["name": name, "font": font, "theme": theme, "scroll": scroll, "columns": columns, "scale": scale, "immersive": immersive, "wide": wide], in: nil, in: .page) { result in continuation.resume(with: result) }
            }
            let text = output as? String ?? "{}"
            let record = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
            try Data(text.utf8).write(to: directory.appendingPathComponent(name + "-metrics.json"))
            readerSmokeCheckpoint("\(name): snapshot")
            let picture: NSImage = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? EPUBImportError.invalid("Appearance snapshot failed.")) }
                }
            }
            guard let tiff = picture.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw EPUBImportError.invalid("Appearance image encoding failed.") }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
            guard record["fontsLoaded"] as? Bool == true, record["retained"] as? Bool == true, record["targetVisible"] as? Bool == true, record["outerOverflow"] as? Bool == false else { throw EPUBImportError.invalid("Appearance validation failed for \(name): \(text)") }
            if scroll {
                let frames = record["frames"] as? [[String: Any]] ?? []
                guard frames.allSatisfy({ f in
                    let probe = f["probe"] as? [String: Any] ?? [:]
                    return (probe["top"] as? Double ?? -1) == 0 && abs(probe["movement"] as? Double ?? -1) < 0.1 && (f["renderedBottom"] as? Double ?? .infinity) <= (f["height"] as? Double ?? 0) + 2 && (f["renderedRight"] as? Double ?? .infinity) <= (f["width"] as? Double ?? 0) + 2
                }) else { throw EPUBImportError.invalid("Appearance continuous geometry failed: \(text)") }
            }
            records.append(record)
            readerSmokeCheckpoint("\(name): validated")
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("appearance-summary.json"))
        print("epub-reader-appearance: bundled fonts, palette, width, narrow stress, immersive, semantic target and personal-data checks passed")
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
                let value = try await webView.evaluateJavaScript("JSON.stringify((()=>{const f=[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden'&&f.contentDocument?.body);if(!f)return {};const d=f.contentDocument,s=f.contentWindow.getComputedStyle(d.documentElement);return {continuous:document.querySelector('#reader').classList.contains('continuous-reader'),width:f.clientWidth,columns:s.columnCount,view:s.getPropertyValue('--USER__view').trim(),height:d.scrollingElement.scrollHeight,viewport:f.contentWindow.innerHeight,preferences:window.StillleafReader.exportState().preferences}})())") as? String ?? "{}"
                metrics = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] ?? [:]
                if scrolling ? metrics["continuous"] as? Bool == true : metrics["columns"] as? String == expectedColumns { break }
            } while Date() < deadline
            let preferences = metrics["preferences"] as? [String: Any]
            guard (scrolling ? metrics["continuous"] as? Bool == true : metrics["columns"] as? String == expectedColumns),
                  preferences?["columns"] as? String == columns, preferences?["scroll"] as? Bool == scrolling,
                  try await testHref() == originalHref, try await testNoteLength() == 65_536,
                  try await testBookmarkCount() == 1 else {
                let href = try await testHref(), note = try await testNoteLength(), bookmarks = try await testBookmarkCount()
                throw EPUBImportError.invalid("Native reading mode \(name) failed geometry or state retention: href \(href) (was \(originalHref)), note \(note), bookmarks \(bookmarks), \(metrics)")
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
        // Successful drafts now autosave during close. Exercise the remaining
        // decision path with a synthetic storage-budget refusal, without growing
        // the fixture or changing any production bridge/persistence behavior.
        _ = try await webView.evaluateJavaScript("window.stillleafTestEncode=TextEncoder.prototype.encode; TextEncoder.prototype.encode=function(value){return value.includes('Native draft preserved')?new Uint8Array(2*1024*1024):window.stillleafTestEncode.call(this,value)}; true")
    }
    func testRestoreDraftSaving() async throws {
        _ = try await webView.evaluateJavaScript("TextEncoder.prototype.encode=window.stillleafTestEncode; delete window.stillleafTestEncode; true")
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

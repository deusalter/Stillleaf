import AppKit
import Combine
import WebKit
import BooksCore
import BooksPlatform

/// Explicit user-opened reader windows. OS import never calls this controller.
@MainActor
final class EPUBReaderWindows {
    var windows: [String: EPUBReaderWindow] = [:]
    var opening: [String: UUID] = [:]
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
        owner.chrome.performControl(command)
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
    func deliverPosition(from reader: EPUBReaderWindow) {
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

/// One reader window. Members without `private` are also driven by the fixture checks in `DevTools/EPUBReaderSmoke.swift`.
@MainActor
final class EPUBReaderWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    let publication: EPUBPublication
    var window: NSWindow?
    var closed: (() -> Void)?
    var focused: (() -> Void)?
    var returnToLibrary: (() -> Void)?
    var webView: WKWebView!
    var chrome: NativeReaderChrome!
    private var chromeRequest: UInt64 = 0
    private var chromeGeneration: UInt64 = 0
    private var lastChromeSequence: UInt64 = 0
    private var guardDelegate: ReaderNavigationGuard!
    private let map: ReaderResourceMap
    let payload: String
    let stateURL: URL
    private let stateStore: ReaderStateStore
    private let pageMapStore: ReaderPageMapStore
    let stateWorker = DispatchQueue(label: "Stillleaf.reader-state", qos: .utility)
    private var latestState: Data?
    var closing = false
    private let token = UUID().uuidString
    private var bridge: EPUBReaderBridge!
    var didLoad = false
    var startupError: String?
    private(set) var isReady = false
    var lastSequence: UInt64 = 0
    var nativePosition: NativeReaderPosition?
    var progress: ProgressObservation?
    var traversedContent: ((PageTurnEvidence) -> Void)?
    var positionChanged: (() -> Void)?
    var progressDelivery = ReaderProgressDeliveryGate()
    var progressDeliveryTask: Task<Void, Never>?
    private var gardenSubscription: AnyCancellable?
    /// Keeps the title bar in the page's colour (see `ReaderTitlebar`).
    private var pageSubscription: AnyCancellable?

    /// The Garden setting as the reader should see it right now (Reduce Motion and Low Power already applied).
    static func currentGardenMode() -> String {
        ThemeStore.shared.effectiveGardenMode(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion).rawValue
    }

    /// Passes the app's Garden setting to the margin garden, now and whenever it changes.
    private func sendGardenMode() {
        if gardenSubscription == nil {
            gardenSubscription = ThemeStore.shared.$revision.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.sendGardenMode() }
        }
        guard isReady else { return }
        let mode = Self.currentGardenMode()
        webView.callAsyncJavaScript("window.StillleafReader.setGardenMode?.(mode)", arguments: ["mode": mode], in: nil, in: .page) { _ in }
    }
    var positionFinalized: ((ProgressObservation) -> Void)?

    init(publication: EPUBPublication, directory: URL, stateDirectory: URL) async throws {
        self.publication = publication
        stateURL = stateDirectory.appendingPathComponent(publication.id + ".json")
        stateStore = ReaderStateStore(directory: stateDirectory)
        pageMapStore = ReaderPageMapStore(stateDirectory: stateDirectory)
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
        // The garden's first frame must already honour Off and Still; sendGardenMode() only carries later changes.
        configuration.userContentController.addUserScript(WKUserScript(source:
            "window.__stillleafGardenMode = \"\(Self.currentGardenMode())\";", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Apple Books opens a reader at 1024 x 768.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        Self.liveObjects.add(self); Self.liveObjects.add(webView)
        guardDelegate = ReaderNavigationGuard(resources: map)
        webView.navigationDelegate = self
        let window = ReaderWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = publication.title
        ReaderTitlebar.configure(window)
        window.minSize = NSSize(width: 520, height: 440)
        // Menu-bar (accessory) apps get no full-screen behavior unless a window opts in.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = webView; window.isReleasedWhenClosed = false
        window.delegate = self; window.center(); self.window = window
        chrome = NativeReaderChrome(window: window)
        chrome.visibility.track(webView)
        pageSubscription = chrome.model.$effectiveAppearance.sink { [weak window, weak webView] page in
            if let window { ReaderTitlebar.follow(page: page, in: window) }
            // Past the page's edge, a rubber-band scroll shows the same colour.
            if let color = ReaderTitlebar.color(hex: page["backgroundColor"] as? String) { webView?.underPageBackgroundColor = color }
        }
        chrome.send = { [weak self] command, payload in
            guard let self else { throw ReaderStateValidation.Failure.invalidState }
            return try await self.sendNativeControl(command, payload: payload)
        }
        chrome.returnFocus = { [weak self] in guard let self, !self.closing else { return }; self.window?.makeFirstResponder(self.webView) }
        webView.load(URLRequest(url: map.url(for: "index.html")!))
    }

    func show() { AppPresence.willPresentWindow(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowDidBecomeKey(_ notification: Notification) { focused?() }
    /// Full screen is the page alone: the toolbar and menu bar slide in over it only when the pointer reaches the top.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideMenuBar, .autoHideToolbar]
    }
    func windowDidEnterFullScreen(_ notification: Notification) { chrome.setFullScreen(true) }
    func windowDidExitFullScreen(_ notification: Notification) { chrome.setFullScreen(false) }
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
        // Detach the page completely so WebKit can release the view, its page and its
        // web content process as soon as the window goes.
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeAllContentRuleLists()
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
        if event["type"] as? String == "pageMap" {
            // Layout-only screen counts for the footer, kept so a reopened book shows them at once. Never
            // progress, evidence or reading state, so they bypass all three.
            guard let map = event["pageMap"], JSONSerialization.isValidJSONObject([map]),
                  let data = try? JSONSerialization.data(withJSONObject: map) else { return }
            let store = pageMapStore, publication = self.publication
            stateWorker.async { store.record(data, publication: publication) }
            return
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
                // Assigning a title-bar string relays out the title bar even when it is unchanged.
                let subtitle: String
                if case .failure = outcome { subtitle = "Reading changes could not be saved" } else { subtitle = "" }
                if let window = self?.window, window.subtitle != subtitle { window.subtitle = subtitle }
            }
        }
    }

    func sendNativeControl(_ command: String, payload: [String: Any]?) async throws -> [String: Any] {
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
    func receiveProgress(_ event: [String: Any]) {
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

    func flushPositionUpdate(final: Bool = false) {
        progressDeliveryTask?.cancel()
        progressDeliveryTask = nil
        if progressDelivery.deliver(at: ProcessInfo.processInfo.systemUptime) {
            if final, let progress { positionFinalized?(progress) }
            else { positionChanged?() }
        }
    }

    nonisolated private static func prepare(publication: EPUBPublication, directory: URL, stateURL: URL) throws -> (ReaderResourceMap, String) {
        let executableFolder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Reader"), executableFolder.appendingPathComponent("Reader")].compactMap { $0 }
        let launch = try ReaderLaunch.prepare(publication: publication, directory: directory, shellCandidates: candidates,
                                              stateDirectory: stateURL.deletingLastPathComponent())
        return (launch.resources, launch.payload)
    }
}

extension EPUBReaderWindow {
    /// Readers and their web views still alive in this process, held weakly for teardown checks.
    static let liveObjects = NSHashTable<AnyObject>.weakObjects()
}

private final class EPUBReaderBridge: NSObject, WKScriptMessageHandler {
    weak var owner: EPUBReaderWindow?
    init(owner: EPUBReaderWindow) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak self] in self?.owner?.receive(message) }
    }
}

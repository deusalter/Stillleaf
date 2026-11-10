import Combine
import SwiftUI
import UIKit
import WebKit
@preconcurrency import BooksCore
@preconcurrency import BooksPlatform

/// Hosts the shared renderer for one edition. Loading, the content rule list, the
/// session URL scheme and event validation are the Mac reader's; this class adds
/// UIKit presentation, swipes and the iOS lifecycle. The controls drawn over the
/// page are SwiftUI (`ReaderControls`), driven by `ReaderChrome`.
final class ReaderViewController: UIViewController, WKNavigationDelegate, UIGestureRecognizerDelegate {
    private let edition: Edition
    private let journal: Journal
    /// The reader's controls and lists; SwiftUI draws them over this controller's page.
    let chrome: ReaderChrome
    private let onClose: () -> Void
    private let token = UUID().uuidString
    private var gate: ReaderEventGate
    private var launch: ReaderLaunch?
    private var navigationGuard: ReaderNavigationGuard?
    private(set) var webView: WKWebView?
    private let stateStore: ReaderStateStore
    private let pageMapStore: ReaderPageMapStore
    private let stateWorker = DispatchQueue(label: "Stillleaf.reader-state", qos: .utility)
    private var latestState: Data?
    private var didStart = false
    private(set) var isReady = false
    private var closing = false
    private var finished = false
    private var scrollMode = false
    private var statusStyle: UIStatusBarStyle = .default
    private let spinner = UIActivityIndicatorView(style: .large)
    private var observers: [NSObjectProtocol] = []
    private var chromeRequest = 0
    private var pageColourWatch: AnyCancellable?
    /// True when the book has no saved reader state: it starts with the appearance used last.
    private var firstOpen = false

    /// Called on the main actor for every accepted renderer event; tests observe the reader through it.
    var eventObserver: ((ReaderEventGate.Event) -> Void)?

    init(edition: Edition, journal: Journal, chrome: ReaderChrome? = nil, onClose: @escaping () -> Void) {
        self.edition = edition
        self.journal = journal
        self.chrome = chrome ?? ReaderChrome()
        self.onClose = onClose
        gate = ReaderEventGate(publication: edition.publication, token: token)
        stateStore = ReaderStateStore(directory: journal.paths.readerState)
        pageMapStore = ReaderPageMapStore(stateDirectory: journal.paths.readerState)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var preferredStatusBarStyle: UIStatusBarStyle { statusStyle }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        connectChrome()
        journal.readerOpened(bookID: edition.bookID)
        // The renderer saves on every change; this also covers the moment before suspension.
        observers.append(NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.saveSnapshot() }
        })
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification, UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
                     UIAccessibility.reduceTransparencyStatusDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.chrome.accessibilityChanged() }
            })
        }
        Task { await load() }
    }

    /// Gives the controls their way to reach the renderer and this controller.
    private func connectChrome() {
        chrome.transport = { [weak self] command, payload in
            guard let self else { throw ReaderStateValidation.Failure.invalidState }
            return try await self.sendNativeControl(command, payload: payload)
        }
        chrome.close = { [weak self] in Task { @MainActor [weak self] in await self?.requestClose() } }
        chrome.accessibility = {
            ["reduceMotion": UIAccessibility.isReduceMotionEnabled, "increaseContrast": UIAccessibility.isDarkerSystemColorsEnabled,
             "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled]
        }
        chrome.defaults = .standard
        // A theme chosen in the sheet reaches here as the page's new colour.
        pageColourWatch = chrome.$pageBackground.removeDuplicates().sink { [weak self] hex in
            guard let self, let page = hex.flatMap(Self.colour(hex:)) else { return }
            self.apply(page: page)
        }
        // The renderer's default size suits a window on a desk; a hand-held page reads better a step smaller.
        if UIDevice.current.userInterfaceIdiom == .phone { chrome.firstOpenPreferences = ["fontSize": 1.0] }
    }

    // MARK: - Loading

    private func load() async {
        let edition = self.edition, stateDirectory = journal.paths.readerState
        let shells = [Bundle.main.resourceURL?.appendingPathComponent("Reader", isDirectory: true)].compactMap { $0 }
        do {
            let (launch, fresh) = try await Task.detached(priority: .userInitiated) { () -> (ReaderLaunch, Bool) in
                let saved = try? ReaderStateStore(directory: stateDirectory).load(publication: edition.publication)
                return (try ReaderLaunch.prepare(publication: edition.publication, directory: edition.directory,
                                                 shellCandidates: shells, stateDirectory: stateDirectory), saved == nil)
            }.value
            firstOpen = fresh
            let configuration = try await ReaderWebViewPolicy.configuration(resources: launch.resources)
            configuration.userContentController.add(ReaderMessageProxy(owner: self), name: "readerEvents")
            let quotedToken = String(decoding: try JSONSerialization.data(withJSONObject: token, options: .fragmentsAllowed), as: UTF8.self)
            configuration.userContentController.addUserScript(WKUserScript(source:
                "window.addEventListener('stillleaf-reader-event', e => window.webkit.messageHandlers.readerEvents.postMessage({token: \(quotedToken), event: e.detail}));",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            configuration.userContentController.addUserScript(WKUserScript(source:
                "window.__stillleafGardenMode = \"\(ReaderPreferences.effectiveGardenMode(reduceMotion: UIAccessibility.isReduceMotionEnabled).rawValue)\";", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            configuration.dataDetectorTypes = []
            let webView = WKWebView(frame: view.bounds, configuration: configuration)
            webView.translatesAutoresizingMaskIntoConstraints = false
            webView.navigationDelegate = self
            webView.allowsLinkPreview = false
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.scrollView.bounces = false
            #if DEBUG
            if #available(iOS 16.4, *) { webView.isInspectable = true }
            #endif
            view.insertSubview(webView, belowSubview: spinner)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
            ])
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
                swipe.direction = direction
                swipe.delegate = self
                webView.addGestureRecognizer(swipe)
            }
            self.launch = launch
            self.navigationGuard = ReaderNavigationGuard(resources: launch.resources)
            self.webView = webView
            webView.load(URLRequest(url: launch.resources.url(for: "index.html")!))
        } catch {
            spinner.stopAnimating()
            presentFailure("This book could not open. \(error.localizedDescription)")
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        Task { @MainActor in
            guard let navigationGuard else { decisionHandler(.cancel); return }
            navigationGuard.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await startWhenAvailable() }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            // iOS reclaims web content memory under pressure. Reload from the last saved state.
            isReady = false
            didStart = false
            firstOpen = false
            chrome.disconnect()
            if let launch { webView.load(URLRequest(url: launch.resources.url(for: "index.html")!)) }
        }
    }

    private func startWhenAvailable() async {
        guard !didStart, let webView, let launch, webView.url == launch.resources.url(for: "index.html") else { return }
        do {
            guard try await evaluate("typeof window.StillleafReader?.open === 'function'") as? Bool == true, !didStart else { return }
            didStart = true
            _ = try await evaluate("window.StillleafReader.open(\(launch.payload)).catch(() => {}); true")
        } catch {
            presentFailure("This book could not open. \(error.localizedDescription)")
        }
    }

    // MARK: - Renderer events

    fileprivate func receive(_ message: WKScriptMessage) {
        let fromSession = message.frameInfo.isMainFrame && launch.map { message.frameInfo.request.url == $0.resources.url(for: "index.html") } == true
        let event = gate.classify(message.body, fromSessionMainFrame: fromSession)
        switch event {
        case .available:
            Task { await startWhenAvailable() }
        case .ready:
            isReady = true
            spinner.stopAnimating()
            journal.readerBecameReady(bookID: edition.bookID)
            matchPageColours()
            let fresh = firstOpen
            firstOpen = false
            Task {
                await chrome.connect(firstOpen: fresh)
                matchPageColours()
            }
        case .closeRequest:
            Task { await requestClose() }
        case .failed:
            isReady = false
        case .state(let data):
            latestState = data
            scrollMode = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["preferences"] as? [String: Any] }?["scroll"] as? Bool ?? false
            persist(data)
            matchPageColours()
        case .position(_, let observation):
            journal.readerMoved(observation)
        case .forwardCoverage(let evidence):
            if isReady { journal.readerTraversed(bookID: edition.bookID, evidence: evidence) }
        case .pageMap(let data):
            // Kept so a reopened book shows its exact page count at once; ReaderLaunch hands it back.
            let store = pageMapStore, publication = edition.publication
            stateWorker.async { store.record(data, publication: publication) }
        case .chrome(let data):
            if let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { chrome.accept(value) }
            matchPageColours()
        case .chromeTap:
            chrome.toggleControls()
        case .ignored:
            break
        }
        if event != .ignored { eventObserver?(event) }
    }

    private func persist(_ data: Data) {
        let store = stateStore, publication = edition.publication
        stateWorker.async { try? store.save(data, publication: publication) }
    }

    private func save(_ data: Data) async throws {
        let store = stateStore, publication = edition.publication
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateWorker.async {
                do { try store.save(data, publication: publication); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Exports and stores the full reader state (position, notes, bookmarks, appearance).
    private func saveSnapshot() async {
        guard isReady, !finished, let snapshot = try? await evaluate("JSON.stringify(window.StillleafReader.exportState())") as? String else { return }
        let data = Data(snapshot.utf8)
        guard (try? ReaderStateValidation.validate(data, publication: edition.publication)) != nil else { return }
        latestState = data
        try? await save(data)
    }

    // MARK: - Closing

    /// Lets the renderer resolve an unsaved note, saves the final state, then closes.
    func requestClose() async {
        guard !closing, !finished else { return }
        closing = true
        defer { closing = false }
        do {
            if isReady {
                let mayClose = try await callAsync("return window.StillleafReader.prepareClose ? await window.StillleafReader.prepareClose() : true")
                guard mayClose as? Bool == true else { return }
                guard let snapshot = try await evaluate("JSON.stringify(window.StillleafReader.exportState())") as? String else {
                    throw ReaderStateValidation.Failure.invalidState
                }
                let data = Data(snapshot.utf8)
                try ReaderStateValidation.validate(data, publication: edition.publication)
                latestState = data
            }
            if let data = latestState { try await save(data) }
        } catch {
            guard await confirmCloseWithoutSaving(error) else { return }
        }
        finish()
        onClose()
    }

    /// Ends tracking and releases the renderer. Idempotent; SwiftUI also calls it on dismantle.
    func finish() {
        guard !finished else { return }
        finished = true
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        // Detach the page completely so WebKit can release the view, its page and its
        // web content process once the reader goes; the Mac reader does the same.
        if let controller = webView?.configuration.userContentController {
            controller.removeScriptMessageHandler(forName: "readerEvents")
            controller.removeAllUserScripts()
            controller.removeAllContentRuleLists()
        }
        pageColourWatch = nil
        chrome.disconnect()
        chrome.transport = nil
        chrome.close = nil
        journal.readerClosed(bookID: edition.bookID)
    }

    private func confirmCloseWithoutSaving(_ error: Error) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: "Your latest reading changes could not be saved",
                message: "Keep the book open to retain your notes and position, or close without saving the latest changes. \(error.localizedDescription)",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Keep Open", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Close Without Saving", style: .destructive) { _ in continuation.resume(returning: true) })
            present(alert, animated: true)
        }
    }

    private func presentFailure(_ message: String) {
        let alert = UIAlertController(title: "Can't Open Book", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .default) { [weak self] _ in
            self?.finish()
            self?.onClose()
        })
        present(alert, animated: true)
    }

    // MARK: - Touch

    /// Horizontal swipes turn pages through the renderer's own page-turn path, so they
    /// produce the same position and coverage events as edge taps, keys and trackpads.
    @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
        // Saved state can start a book in continuous scrolling before any state event has arrived.
        let scrolling = chrome.connected ? chrome.flag("scroll") : scrollMode
        guard isReady, !scrolling, chrome.sheet == nil else { return }
        chrome.setControlsVisible(false)
        let rightToLeft = edition.publication.readingProgression == "rtl"
        let forward = (recognizer.direction == .left) != rightToLeft
        let method = forward ? "next" : "previous"
        webView?.evaluateJavaScript("(() => { if (!document.querySelector('dialog[open]')) window.StillleafReader.\(method)(); return true })()")
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    /// Reads the page colour before the controls have connected; afterwards `chrome.pageBackground` carries it.
    private func matchPageColours() {
        if let page = chrome.pageBackground.flatMap(Self.colour(hex:)) { apply(page: page); return }
        webView?.evaluateJavaScript("getComputedStyle(document.documentElement).getPropertyValue('--paper').trim()") { [weak self] value, _ in
            guard let self, let page = (value as? String).flatMap(Self.colour(hex:)) else { return }
            self.apply(page: page)
        }
    }

    /// The page is one surface: the areas outside the safe area take its colour, and the status bar, the
    /// controls and the home indicator follow a dark or light page whatever the system setting. The style
    /// is set on the root of this presentation, so it ends with the reader.
    private func apply(page: UIColor) {
        view.backgroundColor = page
        var white: CGFloat = 0
        page.getWhite(&white, alpha: nil)
        let dark = white < 0.5
        var root: UIViewController = self
        while let parent = root.parent { root = parent }
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        if root.overrideUserInterfaceStyle != style { root.overrideUserInterfaceStyle = style }
        let bar: UIStatusBarStyle = dark ? .lightContent : .darkContent
        if bar != statusStyle { statusStyle = bar; setNeedsStatusBarAppearanceUpdate() }
    }

    static func colour(hex: String) -> UIColor? {
        guard let rgb = ReaderChrome.rgb(hex) else { return nil }
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    // MARK: - JavaScript

    /// The completion-handler forms tolerate `undefined` results; the async overlays can trap on them.
    func evaluate(_ script: String) async throws -> Any? {
        guard let webView else { throw ReaderStateValidation.Failure.invalidState }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }

    func callAsync(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        guard let webView else { throw ReaderStateValidation.Failure.invalidState }
        return try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                continuation.resume(with: result.map { Optional($0) })
            }
        }
    }

    /// One versioned command for the renderer's native controls. Request ids only ever increase, and a
    /// response is accepted only for this request and this edition, as on the Mac.
    private func sendNativeControl(_ command: String, payload: [String: Any]?) async throws -> [String: Any] {
        guard isReady, !finished else { throw ReaderStateValidation.Failure.invalidState }
        chromeRequest += 1
        let request = chromeRequest
        var envelope: [String: Any] = ["version": 1, "editionId": edition.publication.id, "id": request, "command": command]
        if let payload { envelope["payload"] = payload }
        let value: Any?
        do {
            value = try await callAsync("return await window.StillleafReader.nativeControl(request)", arguments: ["request": envelope])
        } catch {
            // WebKit wraps a rejected promise; the renderer's own sentence is in the exception message.
            if let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String {
                throw ReaderControlError(message: message.replacingOccurrences(of: "Error: ", with: ""))
            }
            throw error
        }
        guard let response = value as? [String: Any], (response["requestId"] as? NSNumber)?.intValue == request,
              response["editionId"] as? String == edition.publication.id else { throw ReaderStateValidation.Failure.invalidState }
        return response
    }
}

/// WKUserContentController retains its handlers; this proxy keeps the reader releasable.
private final class ReaderMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: ReaderViewController?
    init(owner: ReaderViewController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak self] in self?.owner?.receive(message) }
    }
}

/// Hosts `ReaderViewController` in SwiftUI.
struct ReaderPage: UIViewControllerRepresentable {
    let edition: Edition
    let journal: Journal
    let chrome: ReaderChrome
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> ReaderViewController {
        ReaderViewController(edition: edition, journal: journal, chrome: chrome, onClose: onClose)
    }

    func updateUIViewController(_ controller: ReaderViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: ReaderViewController, coordinator: ()) {
        controller.finish()
    }
}

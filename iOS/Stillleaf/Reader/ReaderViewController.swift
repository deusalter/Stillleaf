import UIKit
import WebKit
import BooksCore
import BooksPlatform

/// Hosts the shared renderer for one edition. Loading, the content rule list, the
/// session URL scheme and event validation are the Mac reader's; this class adds
/// UIKit presentation, swipes and the iOS lifecycle.
final class ReaderViewController: UIViewController, WKNavigationDelegate, UIGestureRecognizerDelegate {
    private let edition: Edition
    private let journal: Journal
    private let onClose: () -> Void
    private let token = UUID().uuidString
    private var gate: ReaderEventGate
    private var launch: ReaderLaunch?
    private var navigationGuard: ReaderNavigationGuard?
    private(set) var webView: WKWebView?
    private let stateStore: ReaderStateStore
    private let stateWorker = DispatchQueue(label: "Stillleaf.reader-state", qos: .utility)
    private var latestState: Data?
    private var didStart = false
    private(set) var isReady = false
    private var closing = false
    private var finished = false
    private var scrollMode = false
    private var statusStyle: UIStatusBarStyle = .default
    private let spinner = UIActivityIndicatorView(style: .large)
    private let topFill = UIView()
    private var observers: [NSObjectProtocol] = []

    /// Called on the main actor for every accepted renderer event; tests observe the reader through it.
    var eventObserver: ((ReaderEventGate.Event) -> Void)?

    init(edition: Edition, journal: Journal, onClose: @escaping () -> Void) {
        self.edition = edition
        self.journal = journal
        self.onClose = onClose
        gate = ReaderEventGate(publication: edition.publication, token: token)
        stateStore = ReaderStateStore(directory: journal.paths.readerState)
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
        topFill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topFill)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            topFill.topAnchor.constraint(equalTo: view.topAnchor),
            topFill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topFill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topFill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        journal.readerOpened(bookID: edition.bookID)
        // The renderer saves on every change; this also covers the moment before suspension.
        observers.append(NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.saveSnapshot() }
        })
        Task { await load() }
    }

    // MARK: - Loading

    private func load() async {
        let edition = self.edition, stateDirectory = journal.paths.readerState
        let shells = [Bundle.main.resourceURL?.appendingPathComponent("Reader", isDirectory: true)].compactMap { $0 }
        do {
            let launch = try await Task.detached(priority: .userInitiated) {
                try ReaderLaunch.prepare(publication: edition.publication, directory: edition.directory,
                                         shellCandidates: shells, stateDirectory: stateDirectory)
            }.value
            let configuration = try await ReaderWebViewPolicy.configuration(resources: launch.resources)
            configuration.userContentController.add(ReaderMessageProxy(owner: self), name: "readerEvents")
            let quotedToken = String(decoding: try JSONSerialization.data(withJSONObject: token, options: .fragmentsAllowed), as: UTF8.self)
            configuration.userContentController.addUserScript(WKUserScript(source:
                "window.addEventListener('stillleaf-reader-event', e => window.webkit.messageHandlers.readerEvents.postMessage({token: \(quotedToken), event: e.detail}));",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            configuration.userContentController.addUserScript(WKUserScript(source:
                "window.__stillleafGardenMode = \"\(ReaderPreferences.effectiveGardenMode.rawValue)\";", injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "readerEvents")
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
        guard isReady, !scrollMode else { return }
        let rightToLeft = edition.publication.readingProgression == "rtl"
        let forward = (recognizer.direction == .left) != rightToLeft
        let method = forward ? "next" : "previous"
        webView?.evaluateJavaScript("(() => { if (!document.querySelector('dialog[open]')) window.StillleafReader.\(method)(); return true })()")
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    /// Fills the status-bar area with the reader toolbar's colour and picks a legible status bar.
    private func matchPageColours() {
        let script = "(() => { const s = e => e ? getComputedStyle(e).backgroundColor : ''; return [s(document.querySelector('.reader-bar')), s(document.body)] })()"
        webView?.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, let colours = value as? [String] else { return }
            let bar = colours.first.flatMap(Self.colour), page = colours.last.flatMap(Self.colour)
            if let page { self.view.backgroundColor = page }
            if let fill = bar ?? page {
                self.topFill.backgroundColor = fill
                var white: CGFloat = 0
                fill.getWhite(&white, alpha: nil)
                let style: UIStatusBarStyle = white < 0.5 ? .lightContent : .darkContent
                if style != self.statusStyle { self.statusStyle = style; self.setNeedsStatusBarAppearanceUpdate() }
            }
        }
    }

    /// Parses `rgb(r, g, b)` / `rgba(r, g, b, a)`; transparent colours are ignored.
    static func colour(_ css: String) -> UIColor? {
        let numbers = css.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        guard numbers.count >= 3, (numbers.count < 4 || numbers[3] > 0.5) else { return nil }
        return UIColor(red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: 1)
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

    func callAsync(_ body: String) async throws -> Any? {
        guard let webView else { throw ReaderStateValidation.Failure.invalidState }
        return try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result.map { Optional($0) })
            }
        }
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

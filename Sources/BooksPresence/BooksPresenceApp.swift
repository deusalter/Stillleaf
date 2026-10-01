import AppKit
import SwiftUI
import BooksPlatform
import BooksCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var instance: SingleInstance?
    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private var menuPanel: StatusMenuPanel?
    private var menuPanelSizeObservation: NSKeyValueObservation?
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?
    private var dashboard: NSWindow?
    private var onboarding: NSWindow?
    private var shutdownSignal: DispatchSourceSignal?
    private var diagnosticTimer: Timer?
    private var pendingEPUBURLs: [URL] = []
    private var pendingEPUBOverflow = 0
    private var awaitingReaderTermination = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume(); shutdownSignal = termination
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BooksPresence", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
            instance = try SingleInstance(lockURL: support.appendingPathComponent("tracker.lock"))
            // Read before the model creates its database: an existing history means an upgrade, not a first launch.
            let returning = FileManager.default.fileExists(atPath: support.appendingPathComponent("history.sqlite").path)
            let state = try AppModel(support: support)
            model = state
            state.dashboardAction = { [weak self] in self?.showDashboard() }
            state.onboardingAction = { [weak self] in self?.showOnboarding() }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = PageleafIdentity.statusImage
            item.button?.toolTip = "Stillleaf — reading activity"
            item.button?.target = self; item.button?.action = #selector(togglePopover)
            statusItem = item
            menuPanel = makeMenuPanel(model: state)
            NSApp.mainMenu = AppPresence.makeMainMenu(dashboardTarget: self, dashboardAction: #selector(openDashboard))
            let center = NotificationCenter.default
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                let closing = note.object as? NSWindow
                Task { @MainActor in AppPresence.refresh(closing: closing) }
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
                center.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in AppPresence.refresh() } }
            }
            if state.needsOnboarding {
                if returning { state.markOnboardingComplete() } else { showOnboarding() }
            }
            if !pendingEPUBURLs.isEmpty {
                let urls = pendingEPUBURLs; pendingEPUBURLs.removeAll()
                state.epubLibrary.enqueue(urls)
                if pendingEPUBOverflow > 0 {
                    state.errorMessage = "The launch batch exceeded 1,000 files. Import the remaining \(pendingEPUBOverflow) files in another batch."
                    pendingEPUBOverflow = 0
                }
            }
            // Explicit developer diagnostic, overwritten in place; normal launches create no report.
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--status-report"), index + 1 < arguments.count {
                let url = URL(fileURLWithPath: arguments[index + 1])
                try state.writeStatusReport(to: url)
                diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak state] _ in
                    Task { @MainActor [weak state] in try? state?.writeStatusReport(to: url) }
                }
            }
        } catch let error as POSIXError where error.code == .EWOULDBLOCK {
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert(); alert.messageText = "Stillleaf could not start"; alert.informativeText = String(describing: error); alert.runModal(); NSApp.terminate(nil)
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.epubLibrary.enqueue(urls) }
        else {
            let remaining = EPUBImportQueue.maximumItems - pendingEPUBURLs.count
            pendingEPUBURLs.append(contentsOf: urls.prefix(remaining))
            pendingEPUBOverflow += max(0, urls.count - remaining)
        }
    }
    @objc private func togglePopover() {
        guard let panel = menuPanel else { return }
        if panel.isVisible { dismissMenuPanel() }
        else { showMenuPanel() }
    }
    func showDashboard() {
        guard let model else { return }
        dismissMenuPanel()
        if dashboard == nil {
            let window = DashboardWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Stillleaf"; window.titlebarAppearsTransparent = false
            // Menu-bar (accessory) apps get no full-screen behavior unless a window opts in.
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.contentViewController = NSHostingController(rootView: DashboardView(model: model))
            window.isReleasedWhenClosed = false; window.delegate = self; window.center()
            dashboard = window
        }
        AppPresence.willPresentWindow()
        dashboard?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func readerControl(_ sender: NSMenuItem) { if let command = sender.representedObject as? String { model?.performReaderControl(command) } }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(readerControl(_:)) { return model?.hasNativeReaderCommands == true }
        return true
    }
    @objc private func openDashboard() { showDashboard() }
    @objc func openSettings() { model?.showDashboard(section: .settings) }
    @objc func openLibrary() { model?.showDashboard(section: .library) }
    /// The welcome tour. Closing it early counts as done; Settings can replay it.
    func showOnboarding() {
        guard let model else { return }
        dismissMenuPanel()
        if onboarding == nil {
            let size = OnboardingView.size
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Welcome to Stillleaf"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            let view = OnboardingView(model: model, flow: OnboardingFlow(model: model)) { [weak self] destination in
                self?.finishOnboarding(destination)
            }
            window.contentViewController = NSHostingController(rootView: view)
            window.setContentSize(size)
            window.isReleasedWhenClosed = false; window.delegate = self; window.center()
            onboarding = window
        }
        onboarding?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func finishOnboarding(_ destination: OnboardingDestination) {
        guard let model else { return }
        model.markOnboardingComplete()
        onboarding?.close()
        switch destination {
        case .menuBar: showMenuPanel()
        case .dashboard: showDashboard()
        case .importBooks: model.epubLibrary.chooseFiles()
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboarding else { return }
        model?.markOnboardingComplete()
        // Release after the close finishes; a replay starts a fresh tour.
        Task { @MainActor [weak self] in self?.onboarding = nil }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if !awaitingReaderTermination {
            awaitingReaderTermination = true
            Task { @MainActor in
                let ready = await model.prepareReaderTermination()
                awaitingReaderTermination = false
                sender.reply(toApplicationShouldTerminate: ready)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        dismissMenuPanel()
        menuPanelSizeObservation?.invalidate()
        model?.shutdown()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = menuPanel, notification.object as? NSWindow === panel else { return }
        dismissMenuPanel()
    }

    private func makeMenuPanel(model: AppModel) -> StatusMenuPanel {
        let panel = StatusMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 430),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.cancelHandler = { [weak self] in self?.dismissMenuPanel() }

        let controller = NSHostingController(rootView: PopoverView(model: model, maximumHeight: max(300, min(640, (NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 700) - 24))))
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 22
        panel.contentView?.layer?.masksToBounds = true
        menuPanelSizeObservation = controller.observe(\.preferredContentSize, options: [.initial, .new]) { [weak self, weak panel] controller, _ in
            Task { @MainActor [weak self, weak panel] in
                guard let panel, controller.preferredContentSize.width > 0, controller.preferredContentSize.height > 0 else { return }
                panel.setContentSize(controller.preferredContentSize)
                if panel.isVisible { self?.positionMenuPanel() }
            }
        }
        return panel
    }

    private func showMenuPanel() {
        guard let panel = menuPanel else { return }
        positionMenuPanel()
        installMenuDismissalMonitors()
        panel.makeKeyAndOrderFront(nil)
    }

    private func dismissMenuPanel() {
        menuPanel?.orderOut(nil)
        removeMenuDismissalMonitors()
    }

    private func positionMenuPanel() {
        guard let panel = menuPanel, let button = statusItem?.button, let window = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let anchor = window.convertToScreen(buttonRect)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        let panelSize = panel.frame.size
        let horizontalPadding: CGFloat = 8
        let x = min(max(anchor.midX - panelSize.width / 2, visibleFrame.minX + horizontalPadding), visibleFrame.maxX - panelSize.width - horizontalPadding)
        let y = max(visibleFrame.minY + horizontalPadding, anchor.minY - panelSize.height - 6)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installMenuDismissalMonitors() {
        guard outsideClickMonitor == nil, escapeKeyMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissMenuPanel() }
        }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.menuPanel?.isVisible == true else { return event }
            self?.dismissMenuPanel()
            return nil
        }
    }

    private func removeMenuDismissalMonitors() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor); outsideClickMonitor = nil }
        if let monitor = escapeKeyMonitor { NSEvent.removeMonitor(monitor); escapeKeyMonitor = nil }
    }
}

private final class StatusMenuPanel: NSPanel {
    var cancelHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        cancelHandler?()
    }
}

@main
struct BooksPresenceMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        // Screenshot fixtures can render native views without joining the window list or taking focus.
        let offscreenPreview = CommandLine.arguments.contains("--render-ui") && CommandLine.arguments.contains("--offscreen")
        application.setActivationPolicy(offscreenPreview ? .prohibited : .accessory)
        if CommandLine.arguments.contains("--preview-library") {
            do { try runInteractiveLibraryPreview(); exit(0) }
            catch { fputs("library-preview failed: \(error)\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--self-test-audio"), index + 1 < CommandLine.arguments.count {
            let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                do { try await runAudiobookSmoke(previews: destination); exit(0) }
                catch { fputs("audiobook-native-smoke failed: \(error)\n", stderr); exit(1) }
            }
            application.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--self-test-epub"), index + 1 < CommandLine.arguments.count {
            let fixture = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                do { try await runEPUBReaderSmoke(fixture: fixture); exit(0) }
                catch { fputs("epub-reader-smoke failed: \(error)\n", stderr); exit(1) }
            }
            application.run()
            return
        }
        if CommandLine.arguments.contains("--benchmark-ui") {
            do { try runUIBenchmark(); exit(0) }
            catch { fputs("ui-benchmark failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test-ui") {
            do { try runUISmoke(); exit(0) }
            catch { fputs("ui-smoke failed: \(error)\n", stderr); exit(1) }
        }
        if let argument = CommandLine.arguments.firstIndex(of: "--render-ui"), argument + 1 < CommandLine.arguments.count {
            do { try renderUIPreviews(to: URL(fileURLWithPath: CommandLine.arguments[argument + 1], isDirectory: true)); exit(0) }
            catch { fputs("ui-render failed: \(error)\n", stderr); exit(1) }
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

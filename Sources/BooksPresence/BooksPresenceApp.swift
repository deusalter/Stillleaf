import AppKit
import SwiftUI
import BooksPlatform

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var instance: SingleInstance?
    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var dashboard: NSWindow?
    private var shutdownSignal: DispatchSourceSignal?
    private var diagnosticTimer: Timer?
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
            let state = try AppModel(support: support)
            model = state
            state.dashboardAction = { [weak self] in self?.showDashboard() }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "BooksPresence reading tracker")
            item.button?.toolTip = "BooksPresence — reading activity"
            item.button?.target = self; item.button?.action = #selector(togglePopover)
            statusItem = item
            popover.contentSize = NSSize(width: 350, height: 430)
            popover.behavior = .transient
            let controller = NSHostingController(rootView: PopoverView(model: state))
            controller.sizingOptions = [.preferredContentSize]
            popover.contentViewController = controller
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
            let alert = NSAlert(); alert.messageText = "BooksPresence could not start"; alert.informativeText = String(describing: error); alert.runModal(); NSApp.terminate(nil)
        }
    }
    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    func showDashboard() {
        guard let model else { return }
        popover.performClose(nil)
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "BooksPresence"; window.titlebarAppearsTransparent = true
            window.contentViewController = NSHostingController(rootView: DashboardView(model: model))
            window.isReleasedWhenClosed = false; window.delegate = self; window.center()
            dashboard = window
        }
        dashboard?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

@main
struct BooksPresenceMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
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

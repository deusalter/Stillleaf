import AppKit
import ObjectiveC

/// Smokes, previews and captures run without taking focus from whatever the
/// person at the Mac is doing: the app never activates, and each window it
/// shows is parked at the screen's bottom-right corner with only a sliver on
/// screen. Parked windows still count as visible, so occlusion-gated animation
/// and WebKit keep rendering, and own-window captures still see the whole window.
///
/// On for dev-tool launches unless `STILLLEAF_FOREGROUND_UI=1` or `CI` is set.
/// `--render-native-chrome` tests focus itself, so in background mode it is
/// skipped with a message; CI and foreground runs still execute it.
@MainActor
enum BackgroundUI {
    private(set) static var isEnabled = false
    static let visibleSliver: CGFloat = 24

    private static let launches: Set<String> = [
        "--preview-library", "--self-test-ui", "--self-test-epub", "--self-test-audio",
        "--render-ui", "--benchmark-ui", "--benchmark-settled-ui", "--render-native-chrome"
    ]

    static func enableIfRequested(arguments: [String] = CommandLine.arguments,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !isEnabled, shouldEnable(arguments: arguments, environment: environment) else { return }
        isEnabled = true
        // An accessory app activates when its run loop starts, but a prohibited one cannot show
        // popovers. Start prohibited and become an accessory once launch has finished; changing
        // the policy does not activate the app.
        NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        swizzle(NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)),
                #selector(NSApplication.stillleafBackgroundActivate(ignoringOtherApps:)))
        swizzle(NSApplication.self, NSSelectorFromString("activate"), #selector(NSApplication.stillleafBackgroundActivateNow))
        swizzle(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.stillleafBackgroundMakeKeyAndOrderFront(_:)))
        swizzle(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.stillleafBackgroundOrderFront(_:)))
    }

    static func shouldEnable(arguments: [String], environment: [String: String]) -> Bool {
        guard environment["STILLLEAF_FOREGROUND_UI"] != "1", environment["CI"] == nil else { return false }
        return arguments.contains { launches.contains($0) }
    }

    /// Moves a window so only its top-left corner shows at the bottom-right of the main display.
    static func park(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first, !(window.styleMask.contains(.fullScreen)) else { return }
        let visible = screen.frame
        window.setFrameOrigin(NSPoint(x: visible.maxX - visibleSliver, y: visible.minY - window.frame.height + visibleSliver))
    }

    private static func swizzle(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(type, original), let b = class_getInstanceMethod(type, replacement) else { return }
        method_exchangeImplementations(a, b)
    }
}

extension NSApplication {
    @objc func stillleafBackgroundActivate(ignoringOtherApps flag: Bool) {}
    @objc func stillleafBackgroundActivateNow() {}
}

extension NSWindow {
    @objc func stillleafBackgroundMakeKeyAndOrderFront(_ sender: Any?) {
        orderFrontRegardless()
        MainActor.assumeIsolated { BackgroundUI.park(self) }
        makeKey()
    }

    @objc func stillleafBackgroundOrderFront(_ sender: Any?) {
        orderFrontRegardless()
        MainActor.assumeIsolated { BackgroundUI.park(self) }
    }
}

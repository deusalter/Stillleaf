import AppKit
import ApplicationServices

/// Event notifications supplement the one-second poll. Values and book text are never requested.
public final class BooksWindowObserver {
    private var observer: AXObserver?
    private var pid: pid_t?
    private var observedWindow: AXUIElement?
    private let onChange: () -> Void
    public init(onChange: @escaping () -> Void) { self.onChange = onChange }
    public func refresh() {
        guard BooksCapture.isTrusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: BooksCapture.bundleID).first else { invalidate(); return }
        if pid != app.processIdentifier {
            invalidate()
            var value: AXObserver?
            guard AXObserverCreate(app.processIdentifier, { _, _, _, context in
                guard let context else { return }
                Unmanaged<BooksWindowObserver>.fromOpaque(context).takeUnretainedValue().onChange()
            }, &value) == .success, let value else { return }
            observer = value; pid = app.processIdentifier
            let element = AXUIElementCreateApplication(app.processIdentifier)
            let context = Unmanaged.passUnretained(self).toOpaque()
            for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
                AXObserverAddNotification(value, element, name as CFString, context)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes)
        }
        guard let observer else { return }
        let window = BooksCapture.focusedWindow(pid: app.processIdentifier)
        if let old = observedWindow, let window, CFEqual(old, window) { return }
        if let old = observedWindow {
            for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXTitleChangedNotification] { AXObserverRemoveNotification(observer, old, name as CFString) }
        }
        observedWindow = window
        if let window {
            for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXTitleChangedNotification] { AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque()) }
        }
    }
    public func invalidate() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; pid = nil; observedWindow = nil
    }
    deinit { invalidate() }
}

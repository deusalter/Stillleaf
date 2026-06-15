import AppKit
import ApplicationServices

/// Event notifications supplement the one-second poll. Values and book text are never requested.
public final class BooksWindowObserver {
    private let queue = DispatchQueue(label: "Stillleaf.window-observer", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let pendingLock = NSLock()
    private var refreshPending = false
    private var observer: AXObserver?
    private var pid: pid_t?
    private var observedWindow: AXUIElement?
    private let onChange: () -> Void
    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }
    public func refresh() {
        pendingLock.lock()
        guard !refreshPending else { pendingLock.unlock(); return }
        refreshPending = true
        pendingLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshOnQueue()
            self.pendingLock.lock(); self.refreshPending = false; self.pendingLock.unlock()
        }
    }
    private func refreshOnQueue() {
        guard BooksCapture.isTrusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: BooksCapture.bundleID).first else { clearObserver(); return }
        if pid != app.processIdentifier {
            clearObserver()
            var value: AXObserver?
            guard AXObserverCreate(app.processIdentifier, { _, _, _, context in
                guard let context else { return }
                Unmanaged<BooksWindowObserver>.fromOpaque(context).takeUnretainedValue().onChange()
            }, &value) == .success, let value else { return }
            observer = value; pid = app.processIdentifier
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.1)
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
            AXUIElementSetMessagingTimeout(window, 0.1)
            for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXTitleChangedNotification] { AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque()) }
        }
    }
    public func invalidate() {
        if DispatchQueue.getSpecific(key: queueKey) == true { clearObserver() }
        else { queue.sync { clearObserver() } }
    }
    private func clearObserver() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; pid = nil; observedWindow = nil
    }
    deinit { invalidate() }
}

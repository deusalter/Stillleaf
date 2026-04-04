import AppKit
import ApplicationServices
import BooksCore

public struct CaptureResult {
    public var book: BookRecord?
    public var progress: ProgressObservation?
    public var pauseReason: PauseReason?
    public var health: String
    public var observedAt: Date
    public init(book: BookRecord? = nil, progress: ProgressObservation? = nil, pauseReason: PauseReason? = nil, health: String, observedAt: Date = Date()) {
        self.book = book; self.progress = progress; self.pauseReason = pauseReason; self.health = health; self.observedAt = observedAt
    }
}

public final class BooksCapture {
    public static let bundleID = "com.apple.iBooksX"
    private let catalog: BooksCatalog
    private let covers: CoverCache?
    public init(catalog: BooksCatalog = BooksCatalog(), covers: CoverCache? = nil) { self.catalog = catalog; self.covers = covers }
    public static var isTrusted: Bool { AXIsProcessTrusted() }
    public static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    public static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    public static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let value = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    public func capture() -> CaptureResult {
        guard Self.isTrusted else { return CaptureResult(pauseReason: .permissionLost, health: "Accessibility access is required for automatic tracking. Manual reading is available.") }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == Self.bundleID else { return CaptureResult(pauseReason: .background, health: "Waiting for an Apple Books reading window.") }
        guard let window = Self.focusedWindow(pid: app.processIdentifier) else { return CaptureResult(pauseReason: .noReadingWindow, health: "Books has no accessible focused reading window.") }
        guard (Self.attribute(window, kAXMinimizedAttribute) as? Bool) != true,
              let document = Self.attribute(window, kAXDocumentAttribute) as? String,
              let url = Self.documentURL(document) else {
            return CaptureResult(pauseReason: .noReadingWindow, health: "This Books window does not expose a verifiable document. Library/store windows never count. Use manual mode if this reader is unsupported.")
        }
        do {
            guard var match = try catalog.lookup(documentURL: url) else { return CaptureResult(pauseReason: .noReadingWindow, health: "The active document has no unique catalog identity. Use manual mode for this book.") }
            if let cover = try? covers?.cover(bookID: match.book.id, assetURL: match.assetURL) { match.book.coverPath = cover.path; match.book.coverSource = cover.source }
            return CaptureResult(book: match.book, progress: match.progress, health: "Reader matched by focused document and stable catalog asset ID. Time is inferred reading activity.")
        } catch { return CaptureResult(pauseReason: .captureFailure, health: error.localizedDescription) }
    }
    public static func documentURL(_ value: String) -> URL? {
        if value.hasPrefix("file:"), let u = URL(string: value), u.isFileURL { return u.standardizedFileURL }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL }
        return nil
    }
    /// Only window-level attributes. Never reads AXValue or children, which can expose book prose.
    public static func windowReport(includeMetadata: Bool) -> [[String: Any]] {
        guard isTrusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.4)
        guard let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        let focused = focusedWindow(pid: app.processIdentifier)
        return windows.prefix(20).map { window in
            var item: [String: Any] = ["role": attribute(window, kAXRoleAttribute) as? String ?? "unknown", "subrole": attribute(window, kAXSubroleAttribute) as? String ?? "unknown", "focused": focused.map { CFEqual($0, window) } ?? false, "hasDocument": attribute(window, kAXDocumentAttribute) != nil]
            if includeMetadata { item["title"] = attribute(window, kAXTitleAttribute) as? String; item["document"] = attribute(window, kAXDocumentAttribute) as? String }
            return item
        }
    }
}

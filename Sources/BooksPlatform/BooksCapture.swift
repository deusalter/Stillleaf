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
        guard (Self.attribute(window, kAXMinimizedAttribute) as? Bool) == false,
              (Self.attribute(window, kAXModalAttribute) as? Bool) != true else {
            return CaptureResult(pauseReason: .noReadingWindow, health: "Waiting for an open Books reading window.")
        }
        let initialTitle = Self.attribute(window, kAXTitleAttribute) as? String
        var initialDocument: CFTypeRef?
        let documentResult = AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &initialDocument)
        do {
            var matched: (book: BookRecord, assetURL: URL, progress: ProgressObservation?)?
            if documentResult == .success {
                // A supplied but unsupported document must not fall back to a weaker title match.
                if let document = initialDocument as? String, let url = Self.documentURL(document) { matched = try catalog.lookup(documentURL: url) }
            } else if documentResult == .noValue || documentResult == .attributeUnsupported {
                let evidence = Self.readerEvidence(window)
                if evidence.permitsUniqueTitleMatch, let title = initialTitle {
                    matched = try catalog.lookup(readerTitle: title)
                }
            }
            guard var match = matched else {
                return CaptureResult(pauseReason: .noReadingWindow, health: "This window could not be matched to one reading document. Open the book itself, or use manual reading for an unsupported or ambiguous edition.")
            }
            guard SystemEligibility.booksForeground, let currentWindow = Self.focusedWindow(pid: app.processIdentifier),
                  CFEqual(window, currentWindow), (Self.attribute(window, kAXTitleAttribute) as? String) == initialTitle,
                  (Self.attribute(window, kAXMinimizedAttribute) as? Bool) == false,
                  (Self.attribute(window, kAXModalAttribute) as? Bool) == false else {
                return CaptureResult(pauseReason: .noReadingWindow, health: "The focused Books window changed; waiting for fresh reading evidence.")
            }
            if let initialDocument {
                guard let currentDocument = Self.attribute(window, kAXDocumentAttribute), CFEqual(initialDocument, currentDocument) else {
                    return CaptureResult(pauseReason: .noReadingWindow, health: "The reading document changed; waiting for fresh evidence.")
                }
            } else {
                var currentDocument: CFTypeRef?
                let currentResult = AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &currentDocument)
                guard currentResult == .noValue || currentResult == .attributeUnsupported else {
                    return CaptureResult(pauseReason: .noReadingWindow, health: "The reading document changed; waiting for fresh evidence.")
                }
            }
            if let cover = try? covers?.cover(bookID: match.book.id, assetURL: match.assetURL) { match.book.coverPath = cover.path; match.book.coverSource = cover.source }
            return CaptureResult(book: match.book, progress: match.progress, health: documentResult == .success ? "Reader matched by document path to a stable Books asset. Time is inferred reading activity." : "Books 8.0 reader inferred from window structure and a unique catalog title. Time is inferred reading activity.")
        } catch { return CaptureResult(pauseReason: .captureFailure, health: error.localizedDescription) }
    }
    public static func documentURL(_ value: String) -> URL? {
        if value.hasPrefix("file:"), let u = URL(string: value), u.isFileURL { return u.standardizedFileURL }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL }
        return nil
    }
    /// Inspects structure only. Text values, button labels and web contents are never requested.
    /// A budget overrun or incomplete hierarchy cannot establish a reader.
    private static func readerEvidence(_ window: AXUIElement) -> BooksReaderEvidence {
        let version = Bundle(url: URL(fileURLWithPath: "/System/Applications/Books.app"))?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var evidence = BooksReaderEvidence(booksVersion: version,
            identifier: attribute(window, "AXIdentifier") as? String,
            role: attribute(window, kAXRoleAttribute) as? String,
            subrole: attribute(window, kAXSubroleAttribute) as? String,
            minimized: (attribute(window, kAXMinimizedAttribute) as? Bool) ?? true,
            modal: (attribute(window, kAXModalAttribute) as? Bool) ?? true,
            webAreaCount: 0, hasVisibleReaderWebArea: false, hasLibraryNavigation: false, inspectionComplete: true)
        guard evidence.identifier == "SceneWindow", version == "8.0" else { return evidence }
        let started = ProcessInfo.processInfo.systemUptime
        var visited = Set<CFHashCode>()
        func visit(_ element: AXUIElement, ancestors: [String]) {
            let depth = ancestors.count
            guard !evidence.hasLibraryNavigation, evidence.inspectionComplete else { return }
            guard depth <= 14, visited.count < 120, ProcessInfo.processInfo.systemUptime - started < 0.35 else {
                evidence.inspectionComplete = false; return
            }
            guard visited.insert(CFHash(element)).inserted else { evidence.inspectionComplete = false; return }
            guard let role = attribute(element, kAXRoleAttribute) as? String else { evidence.inspectionComplete = false; return }
            var rawIdentifier: CFTypeRef?
            let identifierResult = AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &rawIdentifier)
            guard identifierResult == .success || identifierResult == .attributeUnsupported || identifierResult == .noValue else {
                evidence.inspectionComplete = false; return
            }
            if identifierResult == .success {
                guard let identifier = rawIdentifier as? String else { evidence.inspectionComplete = false; return }
                if identifier.hasPrefix("iBooksX.tabBar.") { evidence.hasLibraryNavigation = true; return }
            }
            if role == "AXWebArea" {
                evidence.webAreaCount += 1
                var size = CGSize.zero
                let rawSize = attribute(element, kAXSizeAttribute)
                if let rawSize, CFGetTypeID(rawSize) == AXValueGetTypeID() {
                    let value = unsafeBitCast(rawSize, to: AXValue.self)
                    if AXValueGetType(value) == .cgSize, AXValueGetValue(value, .cgSize, &size), size.width > 0, size.height > 0,
                       ancestors == ["AXWindow"] + Array(repeating: "AXGroup", count: 6) {
                        evidence.hasVisibleReaderWebArea = true
                    }
                }
                return
            }
            guard !["AXTextArea", "AXStaticText", "AXTextField"].contains(role) else { return }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            if result == .attributeUnsupported || result == .noValue { return }
            guard result == .success, let children = value as? [AXUIElement] else { evidence.inspectionComplete = false; return }
            guard children.count <= 40 else { evidence.inspectionComplete = false; return }
            for child in children { visit(child, ancestors: ancestors + [role]) }
        }
        visit(window, ancestors: [])
        if ProcessInfo.processInfo.systemUptime - started >= 0.35 { evidence.inspectionComplete = false }
        return evidence
    }

    /// Window metadata by default; opt-in structural metadata never reads prose or AXValue.
    public static func windowReport(includeMetadata: Bool) -> [[String: Any]] {
        guard isTrusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.4)
        guard let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        let focused = focusedWindow(pid: app.processIdentifier)
        return windows.prefix(20).map { window in
            var item: [String: Any] = ["role": attribute(window, kAXRoleAttribute) as? String ?? "unknown", "subrole": attribute(window, kAXSubroleAttribute) as? String ?? "unknown", "focused": focused.map { CFEqual($0, window) } ?? false, "hasDocument": attribute(window, kAXDocumentAttribute) != nil]
            item["roleDescription"] = attribute(window, kAXRoleDescriptionAttribute) as? String
            item["minimized"] = attribute(window, kAXMinimizedAttribute) as? Bool
            if includeMetadata {
                item["title"] = attribute(window, kAXTitleAttribute) as? String
                item["document"] = attribute(window, kAXDocumentAttribute) as? String
                item["identifier"] = attribute(window, "AXIdentifier") as? String
                let evidence = readerEvidence(window)
                item["readerStructure"] = ["webAreaCount": evidence.webAreaCount, "hasVisibleReaderWebArea": evidence.hasVisibleReaderWebArea, "modal": evidence.modal, "hasLibraryNavigation": evidence.hasLibraryNavigation,
                    "inspectionComplete": evidence.inspectionComplete, "permitsUniqueTitleMatch": evidence.permitsUniqueTitleMatch] as [String: Any]
            }
            return item
        }
    }
}

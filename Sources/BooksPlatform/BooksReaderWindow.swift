import AppKit
import ApplicationServices

/// An ephemeral receipt for a successfully matched foreground reader. Checking
/// whether it remains open never reads page contents or matches another window.
public final class BooksReaderWindow {
    private let processID: pid_t
    private let window: AXUIElement
    private let title: String?
    private let document: String?

    init(processID: pid_t, window: AXUIElement, title: String?, document: String?) {
        self.processID = processID; self.window = window; self.title = title; self.document = document
    }

    public var isOpen: Bool {
        guard BooksCapture.isTrusted,
              let application = NSRunningApplication(processIdentifier: processID),
              !application.isTerminated, application.bundleIdentifier == BooksCapture.bundleID else { return false }
        let element = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(element, 0.1)
        AXUIElementSetMessagingTimeout(window, 0.1)
        guard let windows = BooksCapture.attribute(element, kAXWindowsAttribute) as? [AXUIElement],
              windows.prefix(32).contains(where: { CFEqual($0, window) }) else { return false }
        // A reader window repurposed as the library or another title is no
        // longer evidence that this previously shared book remains open.
        if let title, BooksCapture.attribute(window, kAXTitleAttribute) as? String != title { return false }
        if let document, BooksCapture.attribute(window, kAXDocumentAttribute) as? String != document { return false }
        return title != nil || document != nil
    }
}

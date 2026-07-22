import Foundation
import WebKit
import BooksCore

/// Configure before loading any reader document. Imported publication scripts
/// must still be removed: Readium itself requires JavaScript in its frames.
@MainActor
public enum ReaderWebViewPolicy {
    public static func configuration(resources: ReaderResourceMap) async throws -> WKWebViewConfiguration {
        let origin = NSRegularExpression.escapedPattern(for: resources.origin.absoluteString)
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^" + origin], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^blob:"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:"], "action": ["type": "ignore-previous-rules"]]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: rules)
        let source = String(decoding: encoded, as: UTF8.self)
        // The rule contains no book data or source filename. Each session has a
        // unique allowlist origin, so another view cannot broaden these rules.
        let identifier = "StillleafReader-" + resources.origin.host!
        let store = WKContentRuleListStore.default()!
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? URLError(.cannotLoadFromNetwork)) }
            }
        }
        // The compiled object remains retained by its controller. Remove its
        // on-disk reusable cache, since its session origin will never recur.
        try? await store.removeContentRuleList(forIdentifier: identifier)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ReaderSchemeHandler(resources: resources), forURLScheme: "stillleaf-reader")
        configuration.userContentController.add(list)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // The reader window adds its own message handler; it validates the main
        // frame, session token and edition of every message it accepts.
        return configuration
    }
}

/// Keep this object strongly owned by the reader controller (WK delegate is weak).
public final class ReaderNavigationGuard: NSObject, WKNavigationDelegate {
    private let resources: ReaderResourceMap
    public init(resources: ReaderResourceMap) { self.resources = resources }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let frame = navigationAction.targetFrame, let url = navigationAction.request.url else {
            decisionHandler(.cancel); return
        }
        if resources.resource(for: url) != nil {
            decisionHandler(.allow); return
        }
        // Readium creates internal blob-backed child frames. They inherit the
        // content-rule network boundary; never allow them as top-level pages.
        if !frame.isMainFrame && (url.scheme == "blob" || url.absoluteString == "about:blank") {
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
    }
}

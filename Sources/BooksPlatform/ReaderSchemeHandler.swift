import Foundation
import WebKit
import BooksCore

/// Synchronous delivery makes stop/callback ordering deterministic. The bounded
/// immutable map must be prepared off the UI thread before a reader is created.
public final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    public let resources: ReaderResourceMap
    public init(resources: ReaderResourceMap) { self.resources = resources }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard request.httpMethod == "GET" || request.httpMethod == "HEAD",
              let url = request.url, let asset = resources.resource(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return
        }
        // URLResponse avoids relying on HTTP status semantics for custom schemes.
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: asset.mimeType,
                                            expectedContentLength: asset.data.count, textEncodingName: nil))
        if request.httpMethod == "GET" { urlSchemeTask.didReceive(asset.data) }
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

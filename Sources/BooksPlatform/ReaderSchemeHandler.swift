import Foundation
import WebKit
import BooksCore

/// Serves the reader shell from memory and publication files from disk on demand.
/// WebKit calls start/stop on the main thread. File reads run on a background
/// queue; a task WebKit has stopped is never answered, since replying to it traps.
public final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    public let resources: ReaderResourceMap
    private let reader = DispatchQueue(label: "Stillleaf.reader-files", qos: .userInitiated)
    private var running = Set<ObjectIdentifier>()
    public init(resources: ReaderResourceMap) { self.resources = resources }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard request.httpMethod == "GET" || request.httpMethod == "HEAD", let url = request.url else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return
        }
        let includeBody = request.httpMethod == "GET"
        if let asset = resources.resource(for: url) {
            // URLResponse avoids relying on HTTP status semantics for custom schemes.
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: asset.mimeType,
                                                expectedContentLength: asset.data.count, textEncodingName: nil))
            if includeBody { urlSchemeTask.didReceive(asset.data) }
            urlSchemeTask.didFinish()
            return
        }
        guard let file = resources.file(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return
        }
        let task = ObjectIdentifier(urlSchemeTask as AnyObject)
        running.insert(task)
        reader.async { [weak self] in
            let result = Result { try ReaderSchemeHandler.read(file) }
            DispatchQueue.main.async {
                guard let self, self.running.remove(task) != nil else { return }
                switch result {
                case .success(let data):
                    // Renderer fetch() needs an HTTP status to report success.
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                        "Content-Type": file.mimeType, "Content-Length": String(data.count), "Cache-Control": "no-store"
                    ])!
                    urlSchemeTask.didReceive(response)
                    if includeBody { urlSchemeTask.didReceive(data) }
                    urlSchemeTask.didFinish()
                case .failure:
                    urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
                }
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        running.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    /// Reads one imported file, refusing links and files whose size changed since the reader opened.
    static func read(_ file: ReaderResourceMap.FileAsset) throws -> Data {
        let values = try file.file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, values.fileSize == file.byteCount,
              file.byteCount <= ReaderResourceMap.maximumFileAssetBytes else { throw URLError(.resourceUnavailable) }
        let data = try Data(contentsOf: file.file)
        guard data.count == file.byteCount else { throw URLError(.resourceUnavailable) }
        return data
    }
}

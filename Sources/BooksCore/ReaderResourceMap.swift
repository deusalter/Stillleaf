import Foundation

/// An immutable allowlist of already validated resources, with no filesystem API.
/// HTML/CSS sanitization is a separate import responsibility; this is not a sanitizer.
public struct ReaderResourceMap {
    public struct Asset {
        public let data: Data
        public let mimeType: String
        public init(data: Data, mimeType: String) { self.data = data; self.mimeType = mimeType }
    }
    public enum ValidationError: Error { case invalidPath, invalidType, limitExceeded }
    public let origin: URL
    private let assets: [String: Asset]
    private let urls: [String: URL]

    public init(resources: [String: Asset], maximumBytes: Int = 256 * 1_024 * 1_024) throws {
        guard maximumBytes > 0, resources.count <= 10_000 else { throw ValidationError.limitExceeded }
        let origin = URL(string: "stillleaf-reader://s" + UUID().uuidString.lowercased() + "/")!
        var assets: [String: Asset] = [:], urls: [String: URL] = [:]
        var total = 0
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#")
        for (path, asset) in resources {
            guard ReaderLocator(publicationID: "resource", href: path).isValid,
                  !path.contains("%"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed),
                  let url = URL(string: origin.absoluteString + encoded) else { throw ValidationError.invalidPath }
            guard !asset.mimeType.isEmpty, asset.mimeType.utf8.count < 128,
                  asset.mimeType.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
                  asset.mimeType.contains("/") else { throw ValidationError.invalidType }
            guard asset.data.count <= maximumBytes - total else { throw ValidationError.limitExceeded }
            total += asset.data.count
            assets[url.absoluteString] = asset
            urls[path] = url
        }
        self.origin = origin; self.assets = assets; self.urls = urls
    }

    public func url(for path: String) -> URL? { urls[path] }

    /// Exact URL equality deliberately denies query aliases, credentials, ports,
    /// alternate escaping and requests from an earlier reader session.
    public func resource(for url: URL) -> Asset? { assets[url.absoluteString] }
}

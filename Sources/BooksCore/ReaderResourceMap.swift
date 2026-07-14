import Foundation

/// An immutable allowlist of already validated resources, with no filesystem API.
/// HTML/CSS sanitization is a separate import responsibility; this is not a sanitizer.
/// Reader shell files are held in memory. Publication files are only named here,
/// with their expected size, and are read on demand by the platform scheme handler.
public struct ReaderResourceMap {
    public struct Asset {
        public let data: Data
        public let mimeType: String
        public init(data: Data, mimeType: String) { self.data = data; self.mimeType = mimeType }
    }
    /// A publication resource served lazily. Its URL is opaque (`book/<index>`),
    /// so package paths never need to round-trip through URL escaping.
    public struct FileAsset: Equatable {
        public let file: URL
        public let mimeType: String
        public let byteCount: Int
        public init(file: URL, mimeType: String, byteCount: Int) {
            self.file = file; self.mimeType = mimeType; self.byteCount = byteCount
        }
    }
    public enum ValidationError: Error { case invalidPath, invalidType, limitExceeded }
    public static let maximumFileAssetBytes = 32 * 1_024 * 1_024
    public let origin: URL
    private let assets: [String: Asset]
    private let urls: [String: URL]
    private let files: [String: FileAsset]
    private let fileURLs: [URL]

    public init(resources: [String: Asset], files fileAssets: [FileAsset] = [],
                maximumBytes: Int = 256 * 1_024 * 1_024, maximumFileBytes: Int = 256 * 1_024 * 1_024) throws {
        guard maximumBytes > 0, maximumFileBytes >= 0, resources.count <= 10_000, fileAssets.count <= 10_000 else {
            throw ValidationError.limitExceeded
        }
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
            guard Self.isValidMIMEType(asset.mimeType) else { throw ValidationError.invalidType }
            guard asset.data.count <= maximumBytes - total else { throw ValidationError.limitExceeded }
            total += asset.data.count
            assets[url.absoluteString] = asset
            urls[path] = url
        }
        var files: [String: FileAsset] = [:], fileURLs: [URL] = []
        var fileTotal = 0
        for (index, file) in fileAssets.enumerated() {
            guard file.file.isFileURL, let url = URL(string: origin.absoluteString + "book/\(index)"),
                  assets[url.absoluteString] == nil else { throw ValidationError.invalidPath }
            guard Self.isValidMIMEType(file.mimeType) else { throw ValidationError.invalidType }
            guard file.byteCount >= 0, file.byteCount <= Self.maximumFileAssetBytes,
                  file.byteCount <= maximumFileBytes - fileTotal else { throw ValidationError.limitExceeded }
            fileTotal += file.byteCount
            files[url.absoluteString] = file
            fileURLs.append(url)
        }
        self.origin = origin; self.assets = assets; self.urls = urls; self.files = files; self.fileURLs = fileURLs
    }

    /// Printable ASCII `type/subtype`, short enough for a response header.
    public static func isValidMIMEType(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count < 128 && value.contains("/")
            && value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 })
    }

    public func url(for path: String) -> URL? { urls[path] }

    /// The URL for the publication file at `index` in the `files` array.
    public func fileURL(at index: Int) -> URL? { fileURLs.indices.contains(index) ? fileURLs[index] : nil }

    /// Exact URL equality deliberately denies query aliases, credentials, ports,
    /// alternate escaping and requests from an earlier reader session.
    public func resource(for url: URL) -> Asset? { assets[url.absoluteString] }

    /// Same exact-match rule as `resource(for:)`, for publication files.
    public func file(for url: URL) -> FileAsset? { files[url.absoluteString] }
}

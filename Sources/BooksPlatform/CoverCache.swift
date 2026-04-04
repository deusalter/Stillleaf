import AppKit
import CryptoKit
import Foundation

public struct CachedCover { public var path: String; public var source: String }

/// Reads only package metadata and the referenced image. Never scans book prose or contacts the network.
public final class CoverCache {
    private let lock = NSRecursiveLock()
    private let directory: URL
    private let booksIndex: URL
    private var cachedIndexDate: Date?
    private var index: [[String: Any]] = []
    private var lastCheck: [String: (Date, CachedCover?)] = [:]
    public init(directory: URL, booksIndex: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books/Books.plist")) throws {
        self.directory = directory; self.booksIndex = booksIndex
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    public func manualImage(from url: URL, bookID: String) throws -> CachedCover {
        lock.lock(); defer { lock.unlock() }
        let data = try boundedImage(url)
        let result = try cache(data, source: "Manual override")
        lastCheck.removeValue(forKey: bookID)
        return result
    }
    public func cover(bookID: String, assetURL: URL) throws -> CachedCover? {
        lock.lock(); defer { lock.unlock() }
        if let recent = lastCheck[bookID], Date().timeIntervalSince(recent.0) < 60 { return recent.1 }
        var result: CachedCover?
        if let file = try? exactCoverURL(assetURL: assetURL), let data = try? boundedImage(file) {
            result = try cache(data, source: "Apple Books associated artwork")
        } else if let data = try? embeddedCover(assetURL: assetURL) {
            result = try cache(data, source: "Unprotected EPUB embedded cover")
        }
        lastCheck[bookID] = (Date(), result)
        return result
    }
    private func exactCoverURL(assetURL: URL) throws -> URL? {
        let attrs = try FileManager.default.attributesOfItem(atPath: booksIndex.path)
        let modified = attrs[.modificationDate] as? Date
        if index.isEmpty || cachedIndexDate != modified {
            let data = try Data(contentsOf: booksIndex, options: .mappedIfSafe)
            guard data.count < 32 * 1024 * 1024 else { return nil }
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            index = plist?["Books"] as? [[String: Any]] ?? []; cachedIndexDate = modified
        }
        let matches = index.filter { item in
            guard let path = item["path"] as? String else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL == assetURL.standardizedFileURL
        }
        guard matches.count == 1, let info = matches[0]["book-info"] as? [String: Any], let path = info["cover-image-path"] as? String else { return nil }
        return Self.safeChild(path, root: assetURL)
    }
    public static func safeChild(_ path: String, root: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("*"), !path.contains("?"), !path.contains("["), !path.components(separatedBy: "/").contains("..") else { return nil }
        let resolved = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return resolved.path.hasPrefix(base) ? resolved : nil
    }
    private func boundedImage(_ url: URL) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.intValue <= 20 * 1024 * 1024 else { throw BooksAccessError.unavailable("Cover exceeds the 20 MB limit.") }
        let data = try Data(contentsOf: url)
        guard let image = NSImage(data: data), image.isValid else { throw BooksAccessError.unavailable("The selected file is not a supported image.") }
        return data
    }
    private func cache(_ data: Data, source: String) throws -> CachedCover {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let output = directory.appendingPathComponent(digest + ".image")
        if !FileManager.default.fileExists(atPath: output.path) { try data.write(to: output, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path) }
        return CachedCover(path: output.path, source: source)
    }
    private func embeddedCover(assetURL: URL) throws -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: assetURL.path, isDirectory: &isDirectory) else { return nil }
        // Directory EPUBs are the form verified on this host. ZIP EPUBs use bounded entry reads.
        func entry(_ path: String, limit: Int = 1024 * 1024) throws -> Data? {
            guard Self.safeChild(path, root: assetURL) != nil else { return nil }
            if isDirectory.boolValue {
                guard let file = Self.safeChild(path, root: assetURL), let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { return nil }
                return try Data(contentsOf: file)
            }
            return try Self.zipEntry(path, archive: assetURL, limit: limit)
        }
        // Conservatively omit fallback for packages declaring encrypted resources.
        if let encryption = try entry("META-INF/encryption.xml"), !encryption.isEmpty { return nil }
        guard let container = try entry("META-INF/container.xml") else { return nil }
        let rootParser = PackageMetadataParser(); rootParser.read(container)
        guard let package = rootParser.rootfile, let opf = try entry(package) else { return nil }
        let metadata = PackageMetadataParser(); metadata.read(opf)
        guard let href = metadata.coverHref else { return nil }
        let directory = (package as NSString).deletingLastPathComponent
        let relative = directory.isEmpty ? href : directory + "/" + href
        guard let data = try entry(relative.removingPercentEncoding ?? relative, limit: 20 * 1024 * 1024), let image = NSImage(data: data), image.isValid else { return nil }
        return data
    }
    private static func zipEntry(_ path: String, archive: URL, limit: Int) throws -> Data? {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        // A single entry, bounded output, and a timeout prevent malformed archives monopolizing capture.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2); timer.setEventHandler { if process.isRunning { process.terminate() } }; timer.resume()
        defer { timer.cancel() }
        var result = Data()
        while true {
            let part = pipe.fileHandleForReading.readData(ofLength: min(65536, limit + 1 - result.count))
            if part.isEmpty { break }
            result.append(part)
            if result.count > limit { process.terminate(); process.waitUntilExit(); return nil }
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? result : nil
    }
}

private final class PackageMetadataParser: NSObject, XMLParserDelegate {
    var rootfile: String?
    private var coverID: String?
    private var explicitCover: String?
    private var manifest: [String: String] = [:]
    var coverHref: String? { explicitCover ?? coverID.flatMap { manifest[$0] } }
    func read(_ data: Data) { let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = self; _ = parser.parse() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String: String]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "rootfile" { rootfile = attrs["full-path"] }
        if name == "meta", attrs["name"] == "cover" { coverID = attrs["content"] }
        if name == "item", let id = attrs["id"], let href = attrs["href"] {
            manifest[id] = href
            if (attrs["properties"] ?? "").split(separator: " ").contains("cover-image") { explicitCover = href }
        }
    }
}

import Foundation
import CryptoKit
import Darwin
import BooksCore

public struct EPUBPublicationImportResult {
    public let publication: EPUBPublication
    public let directory: URL
    public let alreadyImported: Bool
}
public struct EPUBLibraryRecovery {
    public let publications: [EPUBPublicationImportResult]
    /// At most 20 messages, each at most 512 characters; omitted failures remain counted.
    public let warnings: [String]
    public let failedCount: Int
}

public enum EPUBImportError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// Uses the system libarchive ZIP reader; extraction never follows archive-controlled links.
/// Call off the main thread. A private serial lock protects staging and duplicate resolution.
public final class EPUBPublicationImporter {
    public struct Limits {
        public var compressedBytes = 128 * 1024 * 1024
        public var expandedBytes = 256 * 1024 * 1024
        public var resourceBytes = 32 * 1024 * 1024
        public var entries = 10000
        public init() {}
    }
    private let root: URL
    private let limits: Limits
    private let lock = NSLock()
    public init(directory: URL, limits: Limits = Limits()) { root = directory; self.limits = limits }
    public func importPublication(from source: URL) throws -> EPUBPublicationImportResult {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let kind = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard source.isFileURL, kind.isSymbolicLink != true else { throw EPUBImportError.invalid("Choose a regular EPUB within the import size limit.") }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = root.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        // Apple Books keeps EPUBs added by the reader as unpacked folders; pack one into a ZIP
        // so every archive check below applies unchanged.
        var archive = source
        if kind.isDirectory == true {
            archive = stage.appendingPathComponent("bundle.zip")
            try packBundle(source, into: archive)
        }
        defer { if archive != source { try? fm.removeItem(at: archive) } }
        let values = try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= limits.compressedBytes else { throw EPUBImportError.invalid("Choose a regular EPUB within the import size limit.") }
        // Stream to a bounded private copy, preventing source mutations from changing the validated archive.
        let original = stage.appendingPathComponent("original.epub")
        fm.createFile(atPath: original.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let input = try FileHandle(forReadingFrom: archive), output = try FileHandle(forWritingTo: original)
        defer { try? input.close(); try? output.close() }
        var hash = SHA256(); var copied = 0
        while let data = try input.read(upToCount: 65536), !data.isEmpty {
            copied += data.count
            guard copied <= limits.compressedBytes else { throw EPUBImportError.invalid("EPUB exceeds compressed size limit.") }
            hash.update(data: data); try output.write(contentsOf: data)
        }
        try output.synchronize(); try output.close()
        if archive != source { try? fm.removeItem(at: archive) }
        let id = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let destination = root.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            let existing = try loadReceipt(destination)
            guard existing.id == id else { throw EPUBImportError.invalid("Existing imported edition is inconsistent.") }
            return EPUBPublicationImportResult(publication: existing, directory: destination, alreadyImported: true)
        }
        let content = stage.appendingPathComponent("resources", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: false)
        try preflightZIP(original)
        let paths = try extract(original, to: content)
        // Apple Books Store purchases carry FairPlay rights files. They are never decrypted or imported.
        guard !paths.contains("META-INF/sinf.xml"), !paths.contains("META-INF/rights.xml") else {
            throw EPUBImportError.invalid("This book is protected by Apple Books, so it can only be read in Apple Books.")
        }
        guard paths.contains("mimetype"), try String(contentsOf: content.appendingPathComponent("mimetype"), encoding: .utf8) == "application/epub+zip" else { throw EPUBImportError.invalid("Missing EPUB mimetype.") }
        let container = try parse(content.appendingPathComponent("META-INF/container.xml"))
        guard container.rootName == "container", container.rootNamespace == "urn:oasis:names:tc:opendocument:xmlns:container", let package = container.package else { throw EPUBImportError.invalid("EPUB container has no package.") }
        let packagePath = try Self.safePath(package)
        guard paths.contains(packagePath) else { throw EPUBImportError.invalid("Package document is missing.") }
        let opf = try parse(content.appendingPathComponent(packagePath))
        guard opf.rootName == "package", opf.rootNamespace == "http://www.idpf.org/2007/opf", ["2.0", "3.0"].contains(opf.rootVersion ?? "") else { throw EPUBImportError.invalid("Invalid EPUB package root, namespace, or version.") }
        let base = (packagePath as NSString).deletingLastPathComponent
        var resources: [EPUBResource] = []; var byID: [String: EPUBResource] = [:]
        for item in opf.items {
            let decoded = item.href.removingPercentEncoding ?? ""
            let path = try Self.safePath(base.isEmpty ? decoded : base + "/" + decoded)
            guard paths.contains(path), !item.id.isEmpty, byID[item.id] == nil else { throw EPUBImportError.invalid("Manifest references missing or duplicate resources.") }
            let resource = EPUBResource(id: item.id, path: path, mediaType: item.type)
            resources.append(resource); byID[item.id] = resource
        }
        guard opf.titles.count <= 16, opf.authors.count <= 100, opf.titles.allSatisfy({ $0.utf8.count <= 4096 }), opf.authors.allSatisfy({ $0.utf8.count <= 4096 }), resources.count <= limits.entries, Self.validLanguages(opf.languages), opf.readingProgression.map({ ["ltr", "rtl", "default"].contains($0) }) ?? true else { throw EPUBImportError.invalid("Publication metadata exceeds limits.") }
        let spine = try opf.spine.map { ref -> String in
            guard let resource = byID[ref], ["application/xhtml+xml", "text/html"].contains(resource.mediaType) else { throw EPUBImportError.invalid("Invalid or unsupported reading-order resource.") }
            return resource.path
        }
        guard !spine.isEmpty else { throw EPUBImportError.invalid("EPUB has no readable spine.") }
        let coverID = opf.items.first(where: { $0.properties.split(separator: " ").contains("cover-image") })?.id ?? opf.coverID
        let cover = coverID.flatMap { byID[$0] }.flatMap { ["image/jpeg", "image/png", "image/gif", "image/webp"].contains($0.mediaType) ? $0.path : nil }
        let manifestPaths = Set(resources.map(\.path))
        var navigation: [String: [EPUBNavigationLink]] = [:]
        if let navItem = opf.items.first(where: { $0.properties.split(whereSeparator: { $0.isWhitespace }).contains("nav") }), let nav = byID[navItem.id] {
            navigation = try parseNavigation(content.appendingPathComponent(nav.path), sourcePath: nav.path, manifest: manifestPaths, ncx: false)
        } else if let ncxID = opf.tocID, let ncx = byID[ncxID], ncx.mediaType == "application/x-dtbncx+xml" {
            navigation = try parseNavigation(content.appendingPathComponent(ncx.path), sourcePath: ncx.path, manifest: manifestPaths, ncx: true)
        }
        if navigation["landmarks"] == nil && !opf.guide.isEmpty {
            guard opf.guide.count <= 10000, opf.guide.allSatisfy({ $0.1.utf8.count <= 16384 }) else { throw EPUBImportError.invalid("Guide navigation exceeds limits.") }
            navigation["landmarks"] = try opf.guide.map { EPUBNavigationLink(href: try Self.navigationTarget($0.0, relativeTo: packagePath, manifest: manifestPaths), title: $0.1) }
        }
        if paths.contains("META-INF/encryption.xml") { try deobfuscateFonts(content: content, package: opf, resources: resources) }
        let publication = EPUBPublication(id: id, title: opf.titles.first ?? "Untitled", authors: opf.authors, packagePath: packagePath, resources: resources, spine: spine, coverPath: cover, warnings: ["Publication content is untrusted; the reader must sanitize scripts and deny external requests."], layout: opf.fixedLayout ? "pre-paginated" : "reflowable", languages: opf.languages.isEmpty ? nil : opf.languages, readingProgression: opf.readingProgression, toc: navigation["toc"], landmarks: navigation["landmarks"], pageList: navigation["page-list"])
        try JSONEncoder().encode(publication).write(to: stage.appendingPathComponent("publication.json"), options: .atomic)
        try fm.moveItem(at: stage, to: destination)
        return EPUBPublicationImportResult(publication: publication, directory: destination, alreadyImported: false)
    }
    /// Packs an unpacked EPUB folder: a stored `mimetype` first, then regular files in sorted
    /// order without extra attributes, so the same folder packs to the same edition. Hidden
    /// files are skipped; links are refused rather than followed.
    private func packBundle(_ folder: URL, into archive: URL) throws {
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { throw EPUBImportError.invalid("This book folder could not be read.") }
        var names: [String] = [], total = 0
        while let name = walker.nextObject() as? String {
            let attributes = walker.fileAttributes ?? [:], type = attributes[.type] as? FileAttributeType
            if name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { if type == .typeDirectory { walker.skipDescendants() }; continue }
            guard type != .typeSymbolicLink else { throw EPUBImportError.invalid("This book folder contains links, which are not imported.") }
            guard type == .typeRegular else { continue }
            guard !name.contains("\n"), !name.contains("\r") else { throw EPUBImportError.invalid("This book folder has unsupported file names.") }
            total += (attributes[.size] as? NSNumber)?.intValue ?? 0; names.append(name)
            guard names.count <= limits.entries, total <= limits.expandedBytes else { throw EPUBImportError.invalid("EPUB exceeds expanded size or entry limits.") }
        }
        guard names.contains("mimetype") else { throw EPUBImportError.invalid("Missing EPUB mimetype.") }
        try Self.zip(["-X", "-0", "-q", archive.path, "mimetype"], in: folder)
        let rest = names.filter { $0 != "mimetype" }.sorted()
        if !rest.isEmpty { try Self.zip(["-X", "-D", "-q", "-@", archive.path], in: folder, names: rest) }
    }
    private static func zip(_ arguments: [String], in folder: URL, names: [String]? = nil) throws {
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); process.arguments = arguments; process.currentDirectoryURL = folder
        process.standardInput = names == nil ? FileHandle.nullDevice : input
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        if let names {
            input.fileHandleForWriting.write(Data(names.joined(separator: "\n").appending("\n").utf8))
            try input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw EPUBImportError.invalid("This book folder could not be packed for reading.") }
    }
    /// Loads committed receipts only. Hidden staging directories are never library entries.
    public func loadLibrary() throws -> [EPUBPublicationImportResult] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { directory in
            let id = directory.lastPathComponent
            guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw EPUBImportError.invalid("Invalid managed publication directory.") }
            let publication = try loadReceipt(directory)
            return EPUBPublicationImportResult(publication: publication, directory: directory, alreadyImported: true)
        }
    }
    /// Startup recovery isolates damage to each edition. Root enumeration errors still throw.
    /// Strict loadLibrary remains available for callers requiring an all-valid result.
    public func recoverLibrary() throws -> EPUBLibraryRecovery {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: root.path) else { return EPUBLibraryRecovery(publications: [], warnings: [], failedCount: 0) }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var publications: [EPUBPublicationImportResult] = [], warnings: [String] = []
        var failedCount = 0
        for directory in directories {
            let id = directory.lastPathComponent
            guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }) else { continue }
            do {
                let publication = try loadReceipt(directory)
                publications.append(EPUBPublicationImportResult(publication: publication, directory: directory, alreadyImported: true))
            } catch {
                failedCount += 1
                if warnings.count < 20 { warnings.append(String("Edition \(id.prefix(12)): \(error.localizedDescription)".prefix(512))) }
            }
        }
        return EPUBLibraryRecovery(publications: publications, warnings: warnings, failedCount: failedCount)
    }
    private func loadReceipt(_ directory: URL) throws -> EPUBPublication {
        let fm = FileManager.default
        func regular(_ url: URL, maximum: Int) throws {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= maximum else { throw EPUBImportError.invalid("Missing or unsafe managed publication file.") }
        }
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { throw EPUBImportError.invalid("Unsafe managed publication directory.") }
        let receipt = directory.appendingPathComponent("publication.json")
        try regular(receipt, maximum: 4 * 1024 * 1024)
        try regular(directory.appendingPathComponent("original.epub"), maximum: limits.compressedBytes)
        let publication = try JSONDecoder().decode(EPUBPublication.self, from: Data(contentsOf: receipt))
        guard publication.id == directory.lastPathComponent, !publication.spine.isEmpty, publication.resources.count <= limits.entries,
              publication.title.utf8.count <= 4096, publication.authors.count <= 100, publication.authors.allSatisfy({ $0.utf8.count <= 4096 }), publication.warnings.count <= 100, Self.validLanguages(publication.languages ?? []), publication.readingProgression.map({ ["ltr", "rtl", "default"].contains($0) }) ?? true else { throw EPUBImportError.invalid("Invalid publication receipt.") }
        let original = try FileHandle(forReadingFrom: directory.appendingPathComponent("original.epub"))
        defer { try? original.close() }
        var hash = SHA256(), byteCount = 0
        while let bytes = try original.read(upToCount: 65536), !bytes.isEmpty {
            byteCount += bytes.count
            guard byteCount <= limits.compressedBytes else { throw EPUBImportError.invalid("Managed original exceeds verification limit.") }
            hash.update(data: bytes)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == publication.id else { throw EPUBImportError.invalid("Managed original is corrupted; the existing edition was preserved.") }
        let resourceRoot = directory.appendingPathComponent("resources", isDirectory: true)
        let rootValues = try resourceRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw EPUBImportError.invalid("Unsafe resource directory.") }
        let names = [publication.packagePath] + publication.resources.map(\.path)
        for name in names {
            _ = try Self.safePath(name)
            var url = resourceRoot
            for component in name.split(separator: "/") {
                url.appendPathComponent(String(component))
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw EPUBImportError.invalid("Managed resource contains a symlink.") }
            }
            try regular(url, maximum: limits.resourceBytes)
        }
        let paths = Set(publication.resources.map(\.path))
        guard publication.spine.allSatisfy({ paths.contains($0) }), publication.coverPath.map({ paths.contains($0) }) ?? true,
              fm.fileExists(atPath: resourceRoot.path) else { throw EPUBImportError.invalid("Invalid publication receipt references.") }
        var navigationCount = 0
        func checkLinks(_ links: [EPUBNavigationLink], depth: Int) throws {
            guard depth <= 32 else { throw EPUBImportError.invalid("Navigation nesting exceeds limits.") }
            for link in links {
                navigationCount += 1
                guard navigationCount <= 10000, link.title.utf8.count <= 16384,
                      try Self.navigationTarget(link.href, relativeTo: "", manifest: paths) == link.href else { throw EPUBImportError.invalid("Invalid saved navigation link.") }
                try checkLinks(link.children ?? [], depth: depth + 1)
            }
        }
        try checkLinks((publication.toc ?? []) + (publication.landmarks ?? []) + (publication.pageList ?? []), depth: 0)
        return publication
    }
    private static func navigationTarget(_ href: String, relativeTo source: String, manifest: Set<String>) throws -> String {
        guard href.utf8.count <= 8192, !href.contains("?"), !href.contains("\\"), !href.contains(":"), !href.hasPrefix("/"),
              !href.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw EPUBImportError.invalid("Unsafe EPUB navigation target.") }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = String(parts[0]).removingPercentEncoding else { throw EPUBImportError.invalid("Invalid navigation URL encoding.") }
        var components = source.isEmpty ? [] : (source as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        if path.isEmpty { components = source.split(separator: "/").map(String.init) }
        else {
            for component in path.split(separator: "/", omittingEmptySubsequences: false) {
                if component == ".." { guard !components.isEmpty else { throw EPUBImportError.invalid("Navigation escapes the EPUB root.") }; components.removeLast() }
                else if component == "." { continue }
                else { components.append(String(component)) }
            }
        }
        let normalized = try safePath(components.joined(separator: "/"))
        guard manifest.contains(normalized) else { throw EPUBImportError.invalid("Navigation references a missing manifest resource.") }
        if parts.count == 2 {
            let fragment = String(parts[1])
            guard fragment.utf8.count <= 4096, let decoded = fragment.removingPercentEncoding,
                  !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw EPUBImportError.invalid("Invalid navigation fragment.") }
            return normalized + "#" + fragment
        }
        return normalized
    }
    private func parseNavigation(_ url: URL, sourcePath: String, manifest: Set<String>, ncx: Bool) throws -> [String: [EPUBNavigationLink]] {
        let data = try Data(contentsOf: url)
        guard Self.boundedXMLText(data) != nil else { throw EPUBImportError.invalid("Navigation XML must be bounded UTF-8 without DTD subsets or entities.") }
        let delegate = NavigationXML(ncx: ncx), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.shouldProcessNamespaces = true; parser.shouldReportNamespacePrefixes = true; parser.delegate = delegate
        guard parser.parse(), delegate.validRoot else { throw EPUBImportError.invalid("Invalid EPUB navigation XML.") }
        var count = 0
        func resolve(_ links: [EPUBNavigationLink], depth: Int = 0) throws -> [EPUBNavigationLink] {
            guard depth <= 32 else { throw EPUBImportError.invalid("Navigation nesting exceeds limits.") }
            return try links.map { link in
                count += 1
                guard count <= 10000, link.title.utf8.count <= 16384 else { throw EPUBImportError.invalid("Navigation exceeds limits.") }
                return EPUBNavigationLink(href: try Self.navigationTarget(link.href, relativeTo: sourcePath, manifest: manifest), title: link.title,
                    children: try link.children.map { try resolve($0, depth: depth + 1) })
            }
        }
        var result: [String: [EPUBNavigationLink]] = [:]
        for key in ["toc", "landmarks", "page-list"] { if let links = delegate.sections[key] { result[key] = try resolve(links) } }
        return result
    }
    private static func validLanguages(_ languages: [String]) -> Bool {
        languages.count <= 100 && languages.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }
    }
    public static func safePath(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("%"), !path.contains("?"), !path.contains("#"), !path.contains(where: { "<>|\"*".contains($0) }), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".") && !$0.hasSuffix(" ") && !["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"].contains($0.split(separator: ".").first!.uppercased()) }) else { throw EPUBImportError.invalid("Unsafe or nonportable EPUB resource path.") }
        return path
    }
    /// Raw central-directory validation precedes libarchive because some ZIP readers normalize backslashes.
    /// ZIP64 and split archives are intentionally unsupported within these import bounds.
    private func preflightZIP(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
        func fail() throws -> Never { throw EPUBImportError.invalid("Malformed, unsupported, or unsafe ZIP directory.") }
        guard data.count >= 22 else { try fail() }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if u32(offset) == 0x06054b50, offset + 22 + u16(offset + 20) == data.count { end = offset; break }
        }
        guard let end, u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == u16(end + 10) else { try fail() }
        let count = u16(end + 10), length = u32(end + 12), start = u32(end + 16)
        guard count > 0, count < 65535, count <= limits.entries, start < end, length == end - start else { try fail() }
        var cursor = start, expanded = 0, names = Set<String>(), aliases: [String: String] = [:], regions: [Range<Int>] = []
        for _ in 0..<count {
            guard cursor + 46 <= end, u32(cursor) == 0x02014b50 else { try fail() }
            let flags = u16(cursor + 8), method = u16(cursor + 10), compressed = u32(cursor + 20), size = u32(cursor + 24)
            let n = u16(cursor + 28), extra = u16(cursor + 30), comment = u16(cursor + 32), local = u32(cursor + 42)
            guard flags & 0x0041 == 0, [0, 8].contains(method), u16(cursor + 34) == 0,
                  cursor + 46 + n + extra + comment <= end, n > 0,
                  compressed < 0xffffffff, size <= limits.resourceBytes, size <= limits.expandedBytes - expanded,
                  size <= max(1, compressed) * 1000 else { try fail() }
            let raw = data.subdata(in: cursor + 46..<cursor + 46 + n)
            guard var name = String(data: raw, encoding: .utf8) else { try fail() }
            if name.hasSuffix("/") { name.removeLast() }
            name = try Self.safePath(name)
            guard names.insert(name).inserted else { try fail() }
            var parent = ""
            for part in name.split(separator: "/") {
                parent = parent.isEmpty ? String(part) : parent + "/" + part
                let key = parent.precomposedStringWithCanonicalMapping.lowercased()
                if let prior = aliases[key], prior != parent { try fail() }
                aliases[key] = parent
            }
            guard local + 30 <= start, u32(local) == 0x04034b50, u16(local + 6) == flags, u16(local + 8) == method, u16(local + 26) == n else { try fail() }
            let payload = local + 30 + n + u16(local + 28)
            guard payload <= start, compressed <= start - payload, data.subdata(in: local + 30..<local + 30 + n) == raw else { try fail() }
            if flags & 8 == 0 { guard u32(local + 18) == compressed, u32(local + 22) == size, u32(local + 14) == u32(cursor + 16) else { try fail() } }
            let region = local..<payload + compressed
            guard !regions.contains(where: { $0.overlaps(region) }) else { try fail() }
            regions.append(region); expanded += size; cursor += 46 + n + extra + comment
        }
        guard cursor == end else { try fail() }
    }
    private func extract(_ archiveURL: URL, to content: URL) throws -> Set<String> {
        let api = try ArchiveAPI(); guard let archive = api.create() else { throw EPUBImportError.invalid("Cannot allocate ZIP reader.") }
        defer { _ = api.free(archive) }
        guard api.support(archive) == 0, archiveURL.path.withCString({ api.open(archive, $0, 65536) }) == 0 else { throw EPUBImportError.invalid("Cannot open ZIP archive.") }
        var names = Set<String>(), aliases = Set<String>(), components: [String: String] = [:]; var total = 0, count = 0
        var entry: OpaquePointer?
        while true {
            let status = api.next(archive, &entry)
            if status == 1 { break }
            guard status == 0, let entry, let raw = api.path(entry) else { throw EPUBImportError.invalid("Truncated or malformed ZIP archive.") }
            count += 1
            guard count <= limits.entries, api.encrypted(entry) == 0, api.symlink(entry) == nil, api.hardlink(entry) == nil else { throw EPUBImportError.invalid("ZIP links, encryption, or entry limit rejected.") }
            let type = api.type(entry), directory = type == 0o040000
            var name = String(cString: raw)
            if directory && name.hasSuffix("/") { name.removeLast() }
            name = try Self.safePath(name)
            var parent = ""
            for component in name.split(separator: "/") {
                parent = parent.isEmpty ? String(component) : parent + "/" + component
                let key = parent.precomposedStringWithCanonicalMapping.lowercased()
                if let existing = components[key], existing != parent { throw EPUBImportError.invalid("Case or Unicode alias in ZIP resource path.") }
                components[key] = parent
            }
            let alias = name.precomposedStringWithCanonicalMapping.lowercased()
            guard aliases.insert(alias).inserted, type == 0o100000 || directory else { throw EPUBImportError.invalid("Duplicate, aliased, or special ZIP entry.") }
            let target = content.appendingPathComponent(name)
            if directory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); continue }
            let declared = api.size(entry)
            guard declared >= 0, declared <= limits.resourceBytes, declared <= limits.expandedBytes - total else { throw EPUBImportError.invalid("ZIP expanded size limit exceeded.") }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw EPUBImportError.invalid("Cannot stage resource.") }
            let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
            var buffer = [UInt8](repeating: 0, count: 65536), written = 0
            while true {
                let amount = buffer.withUnsafeMutableBytes { api.read(archive, $0.baseAddress!, $0.count) }
                guard amount >= 0 else { throw EPUBImportError.invalid("Corrupt ZIP resource.") }
                if amount == 0 { break }
                written += amount; total += amount
                guard written <= limits.resourceBytes, total <= limits.expandedBytes, written <= declared else { throw EPUBImportError.invalid("ZIP expanded size limit exceeded.") }
                try output.write(contentsOf: Data(buffer.prefix(amount)))
            }
            guard written == declared else { throw EPUBImportError.invalid("Truncated ZIP resource.") }
            names.insert(name)
        }
        return names
    }
    private func deobfuscateFonts(content: URL, package: PackageXML, resources: [EPUBResource]) throws {
        let data = try Data(contentsOf: content.appendingPathComponent("META-INF/encryption.xml"))
        guard Self.boundedXMLText(data) != nil else { throw EPUBImportError.invalid("Invalid bounded font-obfuscation XML.") }
        let delegate = FontEncryptionXML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.shouldProcessNamespaces = true; parser.delegate = delegate
        guard parser.parse(), !delegate.targets.isEmpty, delegate.targets.count <= limits.entries else { throw EPUBImportError.invalid("Unsupported encryption or missing unique publication identifier.") }
        // IDPF keys are the SHA-1 of the unique identifier; Adobe keys are the 16 bytes of the book's urn:uuid.
        var idpfKey: [UInt8]?, adobeKey: [UInt8]?
        if delegate.targets.contains(where: { $0.algorithm == FontEncryptionXML.idpf }) {
            guard package.identifierValues.count == 1, let identifier = package.identifierValues.first else { throw EPUBImportError.invalid("Unsupported encryption or missing unique publication identifier.") }
            let normalized = identifier.unicodeScalars.filter { ![0x20, 0x09, 0x0D, 0x0A].contains($0.value) }.map(String.init).joined()
            guard !normalized.isEmpty, normalized.utf8.count <= 16384 else { throw EPUBImportError.invalid("Invalid font-obfuscation identifier.") }
            idpfKey = Array(Insecure.SHA1.hash(data: Data(normalized.utf8)))
        }
        if delegate.targets.contains(where: { $0.algorithm == FontEncryptionXML.adobe }) {
            guard let key = Self.adobeFontKey(package.identifierValues + package.otherIdentifierValues) else { throw EPUBImportError.invalid("Adobe font obfuscation needs a urn:uuid publication identifier.") }
            adobeKey = key
        }
        let fontTypes: Set<String> = ["font/otf", "font/ttf", "font/woff", "font/woff2", "font/sfnt", "font/opentype", "font/truetype", "application/vnd.ms-opentype",
                                      "application/font-sfnt", "application/font-woff", "application/x-font-ttf", "application/x-font-otf", "application/x-font-opentype",
                                      "application/x-font-truetype", "application/x-font-woff", "application/font-ttf", "application/font-otf"]
        var targets: [(path: String, adobe: Bool)] = [], seen = Set<String>()
        for target in delegate.targets {
            let uri = target.uri
            guard !uri.contains("?"), !uri.contains("#"), let decoded = uri.removingPercentEncoding else { throw EPUBImportError.invalid("Invalid obfuscated font URI.") }
            let path = try Self.safePath(decoded)
            let matches = resources.filter { $0.path == path }
            guard seen.insert(path).inserted, matches.count == 1, fontTypes.contains(matches[0].mediaType.lowercased()) else { throw EPUBImportError.invalid("Obfuscation must reference a unique manifest font resource.") }
            targets.append((path, target.algorithm == FontEncryptionXML.adobe))
        }
        // Only staged extracted bytes change. The archived original and its SHA256 identity remain intact.
        for target in targets {
            let file = try FileHandle(forUpdating: content.appendingPathComponent(target.path)); defer { try? file.close() }
            let key = (target.adobe ? adobeKey : idpfKey)!, length = target.adobe ? 1024 : 1040
            var prefix = try file.read(upToCount: length) ?? Data()
            for index in prefix.indices { prefix[index] ^= key[index % key.count] }
            // A wrong Adobe key yields noise; leave such a font as it was and let the reader fall back.
            if target.adobe, !Self.looksLikeFont(prefix) { continue }
            try file.seek(toOffset: 0); try file.write(contentsOf: prefix)
        }
    }
    /// One plain DOCTYPE, as in most EPUB 2 NCX files and EPUB 3 XHTML, is allowed. An internal
    /// subset, where entity declarations live, is not, and external entities are never resolved.
    static func boundedXMLText(_ data: Data) -> String? {
        guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { return nil }
        let upper = text.uppercased()
        guard !upper.contains("<!ENTITY") else { return nil }
        let parts = upper.components(separatedBy: "<!DOCTYPE")
        guard parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard let end = parts[1].firstIndex(of: ">"), !parts[1][..<end].contains("[") else { return nil }
        }
        return text
    }
    /// Adobe's legacy scheme XORs the first 1024 bytes with the 16 bytes of a uuid identifier.
    static func adobeFontKey(_ identifiers: [String]) -> [UInt8]? {
        for identifier in identifiers {
            var value = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasPrefix("urn:uuid:") { value.removeFirst("urn:uuid:".count) }
            let hex = Array(value.replacingOccurrences(of: "-", with: ""))
            guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { continue }
            return stride(from: 0, to: 32, by: 2).compactMap { UInt8(String(hex[$0..<$0 + 2]), radix: 16) }
        }
        return nil
    }
    static func looksLikeFont(_ prefix: Data) -> Bool {
        guard prefix.count >= 4 else { return false }
        let signature = Array(prefix.prefix(4))
        return signature == [0x00, 0x01, 0x00, 0x00] || [Array("OTTO".utf8), Array("true".utf8), Array("typ1".utf8), Array("ttcf".utf8), Array("wOFF".utf8), Array("wOF2".utf8)].contains(signature)
    }
    private func parse(_ url: URL) throws -> PackageXML {
        let data = try Data(contentsOf: url)
        guard Self.boundedXMLText(data) != nil else { throw EPUBImportError.invalid("XML metadata must be bounded UTF-8 without DTD subsets or entities.") }
        let parser = XMLParser(data: data), delegate = PackageXML()
        parser.shouldResolveExternalEntities = false; parser.shouldProcessNamespaces = true; parser.delegate = delegate
        guard parser.parse() else { throw EPUBImportError.invalid("Invalid EPUB XML metadata.") }
        return delegate
    }
}
/// A deliberately narrow XML Encryption subset: IDPF and Adobe font obfuscation only, never DRM or external transforms.
private final class FontEncryptionXML: NSObject, XMLParserDelegate {
    static let idpf = "http://www.idpf.org/2008/embedding", adobe = "http://ns.adobe.com/pdf/enc#RC"
    var targets: [(uri: String, algorithm: String)] = []
    private var algorithm = ""
    private var stack: [String] = []
    private var method = false, reference = false, cipher = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let parent = stack.last
        let encryption = "http://www.w3.org/2001/04/xmlenc#"
        switch (stack.count, name, parent) {
        case (0, "encryption", nil):
            guard namespaceURI == "urn:oasis:names:tc:opendocument:xmlns:container" else { parser.abortParsing(); return }
        case (1, "EncryptedData", "encryption"):
            guard namespaceURI == encryption else { parser.abortParsing(); return }
            method = false; reference = false; cipher = false; algorithm = ""
        case (2, "EncryptionMethod", "EncryptedData"):
            guard namespaceURI == encryption, !method, let value = attributes["Algorithm"], [Self.idpf, Self.adobe].contains(value) else { parser.abortParsing(); return }
            method = true; algorithm = value
        case (2, "CipherData", "EncryptedData"):
            guard namespaceURI == encryption, !cipher else { parser.abortParsing(); return }; cipher = true
        case (3, "CipherReference", "CipherData"):
            guard namespaceURI == encryption, !reference, let uri = attributes["URI"], !uri.isEmpty, uri.utf8.count <= 8192 else { parser.abortParsing(); return }
            // XML Encryption orders EncryptionMethod before CipherData.
            guard method else { parser.abortParsing(); return }
            reference = true; targets.append((uri, algorithm))
        default: parser.abortParsing(); return
        }
        // xml:base would change URI meaning and is intentionally unsupported.
        let allowed: Set<String> = name == "EncryptionMethod" ? ["Algorithm"] : name == "CipherReference" ? ["URI"] : []
        guard Set(attributes.keys).isSubset(of: allowed) else { parser.abortParsing(); return }
        stack.append(name)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if string.unicodeScalars.contains(where: { ![0x20, 0x09, 0x0D, 0x0A].contains($0.value) }) { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { parser.abortParsing(); return }
        self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "EncryptedData", !(method && reference && cipher) { parser.abortParsing(); return }
        if !stack.isEmpty { stack.removeLast() }
    }
}
private final class PackageXML: NSObject, XMLParserDelegate {
    struct Item { let id: String; let href: String; let type: String; let properties: String }
    var package: String?, coverID: String?, items: [Item] = [], spine: [String] = [], titles: [String] = [], authors: [String] = []
    var rootName: String?, rootNamespace: String?, rootVersion: String?
    var uniqueIdentifier: String?, identifierValues: [String] = []
    /// Non-unique dc:identifier values; only used to find an Adobe urn:uuid font key.
    var otherIdentifierValues: [String] = []
    private var otherIdentifier = false, otherValue = ""
    private var elements: [String] = []
    private var metadataNamespace: String?
    var fixedLayout = false
    var languages: [String] = []
    var readingProgression: String?
    var tocID: String?
    var guide: [(String, String)] = []
    private var depth = 0
    private var field: String?, value = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if depth == 0 { rootName = name; rootNamespace = namespaceURI; rootVersion = a["version"]; uniqueIdentifier = a["unique-identifier"] }
        depth += 1
        guard depth <= 128, field != "identifier" else { parser.abortParsing(); return }
        if depth == 2, name == "metadata" { metadataNamespace = namespaceURI }
        let parent = elements.last; elements.append(name)
        switch name {
        case "rootfile": if a["media-type"] == "application/oebps-package+xml", package == nil { package = a["full-path"] }
        case "item": items.append(Item(id: a["id"] ?? "", href: a["href"] ?? "", type: a["media-type"] ?? "", properties: a["properties"] ?? ""))
        case "spine": readingProgression = a["page-progression-direction"]; tocID = a["toc"]
        case "reference": if let href = a["href"] { guide.append((href, a["title"] ?? a["type"] ?? "")) }
        case "itemref":
            if a["linear"] != "no" { spine.append(a["idref"] ?? "") }
            if (a["properties"] ?? "").split(separator: " ").contains("rendition:layout-pre-paginated") { fixedLayout = true }
        case "meta":
            if a["name"] == "cover" { coverID = a["content"] }
            if a["property"] == "rendition:layout" { field = "meta"; value = "" }
            if a["name"] == "fixed-layout", a["content"]?.lowercased() == "true" { fixedLayout = true }
        case "title", "creator": field = name; value = ""
        case "identifier":
            if depth == 3, parent == "metadata", metadataNamespace == "http://www.idpf.org/2007/opf", namespaceURI == "http://purl.org/dc/elements/1.1/" {
                if let uniqueIdentifier, !uniqueIdentifier.isEmpty, a["id"] == uniqueIdentifier { field = name; value = "" }
                else if otherIdentifierValues.count < 32 { otherIdentifier = true; otherValue = "" }
            }
        case "language": if namespaceURI == "http://purl.org/dc/elements/1.1/" { field = name; value = "" }
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { value += string }
        if otherIdentifier, otherValue.utf8.count < 1024 { otherValue += string }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { parser.abortParsing(); return }
        self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1; elements.removeLast()
        let name = elementName.split(separator: ":").last.map(String.init)
        if otherIdentifier, name == "identifier" { otherIdentifierValues.append(otherValue); otherIdentifier = false }
        if name == field {
            if field == "identifier" { identifierValues.append(value) }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if field == "title" { titles.append(text) }
                else if field == "creator" { authors.append(text) }
                else if field == "language" { languages.append(text) }
                else if field == "meta", text == "pre-paginated" { fixedLayout = true }
            }
            field = nil
        }
    }
}

/// Bounded XML-only extraction; publication scripts/styles are never evaluated.
private final class NavigationXML: NSObject, XMLParserDelegate {
    private final class Node {
        let depth: Int
        var href: String?, title = "", children: [EPUBNavigationLink] = []
        init(depth: Int) { self.depth = depth }
    }
    let ncx: Bool
    var sections: [String: [EPUBNavigationLink]] = [:]
    var validRoot = false
    private var depth = 0, sectionDepth = 0, textDepth: Int?, count = 0
    private var section: String?, nodes: [Node] = [], prefixes: [String: String] = [:]
    init(ncx: Bool) { self.ncx = ncx }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) { prefixes[prefix] = uri }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { prefixes.removeValue(forKey: prefix) }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        depth += 1
        guard depth <= 128 else { parser.abortParsing(); return }
        if depth == 1 { validRoot = ncx ? name == "ncx" && namespaceURI == "http://www.daisy.org/z3986/2005/ncx/" : name == "html" && namespaceURI == "http://www.w3.org/1999/xhtml" }
        if section == nil {
            if ncx && ["navMap", "pageList"].contains(name) { section = name == "navMap" ? "toc" : "page-list"; sectionDepth = depth }
            else if !ncx && name == "nav" {
                let type = a.first { key, _ in let split = key.split(separator: ":"); return split.count == 2 && split[1] == "type" && prefixes[String(split[0])] == "http://www.idpf.org/2007/ops" }?.value ?? ""
                section = type.split(whereSeparator: { $0.isWhitespace }).map(String.init).first { ["toc", "landmarks", "page-list"].contains($0) }
                sectionDepth = depth
            }
            if let section { sections[section, default: []] = sections[section] ?? [] }
        }
        guard section != nil else { return }
        if (ncx && ["navPoint", "pageTarget"].contains(name)) || (!ncx && name == "li") {
            count += 1
            guard count <= 10000, nodes.count < 32 else { parser.abortParsing(); return }
            nodes.append(Node(depth: depth))
        }
        guard let node = nodes.last else { return }
        if !ncx && name == "a" { node.href = a["href"]; textDepth = depth }
        if ncx && name == "content" { node.href = a["src"] }
        if ncx && name == "text" { textDepth = depth }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textDepth != nil, let node = nodes.last {
            node.title += string
            if node.title.utf8.count > 16384 { parser.abortParsing() }
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if textDepth == depth { textDepth = nil }
        if let node = nodes.last, node.depth == depth {
            nodes.removeLast()
            let links: [EPUBNavigationLink]
            if let href = node.href { links = [EPUBNavigationLink(href: href, title: node.title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "), children: node.children.isEmpty ? nil : node.children)] }
            else { links = node.children }
            if let parent = nodes.last { parent.children.append(contentsOf: links) }
            else if let section { sections[section, default: []].append(contentsOf: links) }
        }
        if sectionDepth == depth { section = nil }
        depth -= 1
    }
}

/// System ABI declarations use C calling convention; no external ZIP process or package is involved.
private final class ArchiveAPI {
    let handle: UnsafeMutableRawPointer
    let create: @convention(c) () -> OpaquePointer?
    let support: @convention(c) (OpaquePointer) -> Int32
    let open: @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int) -> Int32
    let next: @convention(c) (OpaquePointer, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    let read: @convention(c) (OpaquePointer, UnsafeMutableRawPointer, Int) -> Int
    let free: @convention(c) (OpaquePointer) -> Int32
    let path: @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
    let size: @convention(c) (OpaquePointer) -> Int64
    let type: @convention(c) (OpaquePointer) -> UInt32
    let encrypted: @convention(c) (OpaquePointer) -> Int32
    let symlink: @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
    let hardlink: @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
    init() throws {
        guard let h = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { throw EPUBImportError.invalid("System ZIP reader unavailable.") }
        handle = h
        func bind<T>(_ name: String, _: T.Type) throws -> T { guard let symbol = dlsym(h, name) else { throw EPUBImportError.invalid("System ZIP API unavailable: " + name) }; return unsafeBitCast(symbol, to: T.self) }
        do {
            create = try bind("archive_read_new", (@convention(c) () -> OpaquePointer?).self)
            support = try bind("archive_read_support_format_zip", (@convention(c) (OpaquePointer) -> Int32).self)
            open = try bind("archive_read_open_filename", (@convention(c) (OpaquePointer, UnsafePointer<CChar>, Int) -> Int32).self)
            next = try bind("archive_read_next_header", (@convention(c) (OpaquePointer, UnsafeMutablePointer<OpaquePointer?>) -> Int32).self)
            read = try bind("archive_read_data", (@convention(c) (OpaquePointer, UnsafeMutableRawPointer, Int) -> Int).self)
            free = try bind("archive_read_free", (@convention(c) (OpaquePointer) -> Int32).self)
            path = try bind("archive_entry_pathname_utf8", (@convention(c) (OpaquePointer) -> UnsafePointer<CChar>?).self)
            size = try bind("archive_entry_size", (@convention(c) (OpaquePointer) -> Int64).self)
            type = try bind("archive_entry_filetype", (@convention(c) (OpaquePointer) -> UInt32).self)
            encrypted = try bind("archive_entry_is_encrypted", (@convention(c) (OpaquePointer) -> Int32).self)
            symlink = try bind("archive_entry_symlink", (@convention(c) (OpaquePointer) -> UnsafePointer<CChar>?).self)
            hardlink = try bind("archive_entry_hardlink", (@convention(c) (OpaquePointer) -> UnsafePointer<CChar>?).self)
        } catch { dlclose(h); throw error }
    }
    deinit { dlclose(handle) }
}

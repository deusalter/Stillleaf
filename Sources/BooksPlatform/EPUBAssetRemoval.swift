import Foundation
import CryptoKit
import BooksCore

public struct EPUBAssetRemovalResult {
    public let publicationID: String
    public let exportedOriginal: URL?
    public let trashedDirectory: URL
}
public enum EPUBAssetRemovalError: Error, LocalizedError {
    case invalid(String)
    case trashFailed(message: String, exportedOriginal: URL?)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .trashFailed(let message, let exported):
            return exported.map { "The EPUB was saved at \($0.path), but the managed copy could not be moved to Trash: \(message)" } ?? "The managed EPUB could not be moved to Trash: \(message)"
        }
    }
}

/// Removes only a complete, validated app-managed edition. Journal data belongs outside this root.
/// The host must serialize this operation with imports and reader access to the same edition.
public final class EPUBAssetRemoval {
    public typealias TrashOperation = (URL) throws -> URL
    private let root: URL
    private let trash: TrashOperation
    private let lock = NSLock()
    public init(directory: URL, trash: @escaping TrashOperation = EPUBAssetRemoval.systemTrash) {
        root = directory; self.trash = trash
    }
    public static func systemTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw EPUBAssetRemovalError.invalid("Trash did not return the moved edition location.") }
        return result as URL
    }
    public func remove(publicationID: String, keepingOriginalAt export: URL? = nil) throws -> EPUBAssetRemovalResult {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard root.isFileURL, publicationID.count == 64, publicationID.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw EPUBAssetRemovalError.invalid("Invalid managed edition identifier.") }
        try noSymbolicComponents(root)
        let edition = root.appendingPathComponent(publicationID, isDirectory: true)
        try directory(root); try directory(edition)
        let top = try fm.contentsOfDirectory(atPath: edition.path)
        guard Set(top) == Set(["original.epub", "publication.json", "resources"]) else { throw EPUBAssetRemovalError.invalid("The managed edition is incomplete or contains additional data; no files were removed.") }
        let original = edition.appendingPathComponent("original.epub"), receipt = edition.appendingPathComponent("publication.json")
        try regular(original, maximum: 128 * 1024 * 1024)
        try regular(receipt, maximum: 4 * 1024 * 1024)
        let publication = try JSONDecoder().decode(EPUBPublication.self, from: Data(contentsOf: receipt))
        guard publication.id == publicationID, publication.resources.count <= 10000, !publication.spine.isEmpty else { throw EPUBAssetRemovalError.invalid("The managed publication receipt is inconsistent.") }
        let resources = edition.appendingPathComponent("resources", isDirectory: true)
        try directory(resources)
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: resources, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw EPUBAssetRemovalError.invalid("Cannot inspect managed resources.") }
        var count = 0
        for case let entry as URL in enumerator {
            count += 1
            guard count <= 20000 else { throw EPUBAssetRemovalError.invalid("Managed resource tree exceeds expected bounds.") }
            let attributes = try fm.attributesOfItem(atPath: entry.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory { try directory(entry) }
            else { try regular(entry, maximum: 32 * 1024 * 1024) }
        }
        if let enumerationError { throw enumerationError }
        for path in [publication.packagePath] + publication.resources.map(\.path) {
            _ = try EPUBPublicationImporter.safePath(path)
            try regular(resources.appendingPathComponent(path), maximum: 32 * 1024 * 1024)
        }
        let paths = Set(publication.resources.map(\.path))
        guard publication.spine.allSatisfy({ paths.contains($0) }), publication.coverPath.map({ paths.contains($0) }) ?? true else { throw EPUBAssetRemovalError.invalid("The managed publication receipt references missing resources.") }
        guard try digest(original) == publicationID else { throw EPUBAssetRemovalError.invalid("The managed original does not match this edition; no files were removed.") }
        var exported: URL?
        if let export {
            guard export.isFileURL else { throw EPUBAssetRemovalError.invalid("Choose a local destination for the EPUB.") }
            let destination = export
            let parent = destination.deletingLastPathComponent()
            try noSymbolicComponents(parent); try directory(parent)
            let canonicalRoot = root.resolvingSymlinksInPath().path
            let canonicalDestination = parent.resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent).path
            guard canonicalDestination != canonicalRoot, !canonicalDestination.hasPrefix(canonicalRoot + "/"), destination.pathExtension.lowercased() == "epub" else { throw EPUBAssetRemovalError.invalid("Save the EPUB outside Stillleaf's managed library using an .epub filename.") }
            // copyItem does not replace an existing file. Never pre-delete a user-selected destination.
            try fm.copyItem(at: original, to: destination)
            do {
                try regular(destination, maximum: 128 * 1024 * 1024)
                guard try digest(destination) == publicationID else { throw EPUBAssetRemovalError.invalid("Export verification failed; the managed EPUB was retained.") }
            } catch {
                // Preserve this newly created export for inspection instead of risking removal of a changed destination.
                throw EPUBAssetRemovalError.invalid("Export could not be verified at \(destination.path). The managed EPUB was retained: \(error.localizedDescription)")
            }
            exported = destination
        }
        do {
            let trashed = try trash(edition)
            return EPUBAssetRemovalResult(publicationID: publicationID, exportedOriginal: exported, trashedDirectory: trashed)
        } catch { throw EPUBAssetRemovalError.trashFailed(message: error.localizedDescription, exportedOriginal: exported) }
    }
    private func noSymbolicComponents(_ url: URL) throws {
        var current = url.path
        while current != "/" && !current.isEmpty {
            let attributes = try FileManager.default.attributesOfItem(atPath: current)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw EPUBAssetRemovalError.invalid("Managed or export paths cannot pass through symbolic links: \(current)") }
            current = (current as NSString).deletingLastPathComponent
        }
    }
    private func directory(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else { throw EPUBAssetRemovalError.invalid("Missing or unsafe managed directory.") }
    }
    private func regular(_ url: URL, maximum: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximum,
              let links = attributes[.referenceCount] as? NSNumber, links.intValue == 1 else { throw EPUBAssetRemovalError.invalid("Missing, shared, or unsafe managed file.") }
    }
    private func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(), count = 0
        while let data = try file.read(upToCount: 65536), !data.isEmpty {
            count += data.count
            guard count <= 128 * 1024 * 1024 else { throw EPUBAssetRemovalError.invalid("EPUB exceeds verification bounds.") }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

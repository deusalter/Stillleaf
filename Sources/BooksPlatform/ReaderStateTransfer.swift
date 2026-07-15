import Foundation
import CryptoKit
import BooksCore

public enum ReaderStateTransferError: Error, LocalizedError {
    case noState, unsafeFile, conflictRequiresReplacement, staleImport, localChanged
    public var errorDescription: String? {
        switch self {
        case .noState: return "This edition has no saved reader state to export."
        case .unsafeFile: return "Choose a regular reader-state JSON file within the size limit."
        case .conflictRequiresReplacement: return "Review the differing saved state before explicitly replacing it. Notes are not merged."
        case .staleImport: return "The imported revision is older than the local state. Nothing was changed."
        case .localChanged: return "Local reading changes arrived after the preview. Review the import again."
        }
    }
}
public struct ReaderStateTransferExport {
    public let url: URL
    public let sha256: String
    public let bytes: Int
}
public struct ReaderStateImportPreview {
    public enum Disposition { case newEditionState, identical, replacement, stale }
    public let editionID: String
    public let incomingRevision: Double
    public let localRevision: Double?
    public let incomingBookmarks: Int
    public let incomingAnnotations: Int
    public let localBookmarks: Int
    public let localAnnotations: Int
    public let incomingSHA256: String
    public let localSHA256: String?
    public let disposition: Disposition
    fileprivate let data: Data
    fileprivate let publication: EPUBPublication
}

/// Offline per-edition state transfer, not a whole-library archive or merge protocol.
/// The host must close the edition reader and serialize preview/apply with its save queue.
/// ReaderStateStore currently has no cross-instance transactional compare-and-save API.
public final class ReaderStateTransfer {
    private let store: ReaderStateStore
    private let lock = NSLock()
    public init(store: ReaderStateStore) { self.store = store }

    @discardableResult
    public func export(publication: EPUBPublication, to destination: URL) throws -> ReaderStateTransferExport {
        lock.lock(); defer { lock.unlock() }
        guard destination.isFileURL else { throw ReaderStateTransferError.unsafeFile }
        guard let saved = try store.load(publication: publication) else { throw ReaderStateTransferError.noState }
        let data = try Self.canonical(saved, publication: publication)
        let fm = FileManager.default
        // Stage beside the destination; moveItem refuses to replace any existing user file.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".reader-state-export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try fm.moveItem(at: temporary, to: destination)
        return ReaderStateTransferExport(url: destination, sha256: Self.digest(data), bytes: data.count)
    }
    public func previewImport(from source: URL, publication: EPUBPublication) throws -> ReaderStateImportPreview {
        lock.lock(); defer { lock.unlock() }
        guard source.isFileURL else { throw ReaderStateTransferError.unsafeFile }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= ReaderStateValidation.maximumBytes else { throw ReaderStateTransferError.unsafeFile }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            guard chunk.count <= ReaderStateValidation.maximumBytes - bytes.count else { throw ReaderStateTransferError.unsafeFile }
            bytes.append(chunk)
        }
        let incoming = try Self.canonical(bytes, publication: publication)
        let local = try store.load(publication: publication).map { try Self.canonical($0, publication: publication) }
        let incomingRevision = try ReaderStateValidation.revision(incoming)
        let localRevision = try local.map(ReaderStateValidation.revision)
        let incomingHash = Self.digest(incoming), localHash = local.map(Self.digest)
        let disposition: ReaderStateImportPreview.Disposition
        if localHash == incomingHash { disposition = .identical }
        else if let localRevision, incomingRevision < localRevision { disposition = .stale }
        else { disposition = local == nil ? .newEditionState : .replacement }
        let incomingCounts = try Self.counts(incoming), localCounts = try local.map(Self.counts) ?? (0, 0)
        return ReaderStateImportPreview(editionID: publication.id, incomingRevision: incomingRevision, localRevision: localRevision,
            incomingBookmarks: incomingCounts.0, incomingAnnotations: incomingCounts.1, localBookmarks: localCounts.0, localAnnotations: localCounts.1,
            incomingSHA256: incomingHash, localSHA256: localHash, disposition: disposition, data: incoming, publication: publication)
    }
    /// Returns false for an identical no-op. Differing equal/newer revisions require explicit replacement.
    @discardableResult
    public func apply(_ preview: ReaderStateImportPreview, replacingExisting: Bool = false) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let local = try store.load(publication: preview.publication).map { try Self.canonical($0, publication: preview.publication) }
        guard local.map(Self.digest) == preview.localSHA256 else { throw ReaderStateTransferError.localChanged }
        switch preview.disposition {
        case .identical: return false
        case .stale: throw ReaderStateTransferError.staleImport
        case .replacement: guard replacingExisting else { throw ReaderStateTransferError.conflictRequiresReplacement }
        case .newEditionState: break
        }
        try store.save(preview.data, publication: preview.publication)
        return true
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func counts(_ data: Data) throws -> (Int, Int) {
        let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return ((state["bookmarks"] as! [Any]).count, (state["annotations"] as! [Any]).count)
    }
    /// Export only portable contract fields; never carry arbitrary host/private fields.
    private static func canonical(_ data: Data, publication: EPUBPublication) throws -> Data {
        try ReaderStateValidation.validate(data, publication: publication)
        let source = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func pick(_ object: [String: Any], _ keys: [String]) -> [String: Any] { object.filter { keys.contains($0.key) } }
        func locator(_ value: Any?) -> Any {
            guard let value = value as? [String: Any] else { return NSNull() }
            var result = pick(value, ["href", "type", "title"])
            if let locations = value["locations"] as? [String: Any] {
                result["locations"] = pick(locations, ["progression", "totalProgression", "position", "fragments", "cssSelector", "partialCfi", "domRange"])
            }
            if let context = value["text"] as? [String: Any] { result["text"] = pick(context, ["before", "highlight", "after"]) }
            return result
        }
        var result = pick(source, ["schemaVersion", "editionId", "revision"])
        result["position"] = locator(source["position"])
        result["preferences"] = pick(source["preferences"] as! [String: Any], ["theme", "fontFamily", "fontSize", "lineHeight", "measure", "scroll", "fontWeight", "textAlign", "hyphens", "letterSpacing", "wordSpacing", "columns", "margins"])
        for key in ["bookmarks", "annotations"] {
            let keys = key == "bookmarks" ? ["id", "label", "createdAt"] : ["id", "quote", "note", "color", "createdAt", "updatedAt"]
            result[key] = (source[key] as! [[String: Any]]).map { item -> [String: Any] in
                var saved = pick(item, keys); saved["locator"] = locator(item["locator"]); return saved
            }
        }
        let resultData = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try ReaderStateValidation.validate(resultData, publication: publication)
        return resultData
    }
}

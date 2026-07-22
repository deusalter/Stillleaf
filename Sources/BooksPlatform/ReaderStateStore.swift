import Foundation
import BooksCore

/// State lives outside publication assets. The host serializes access to one store instance.
public final class ReaderStateStore {
    private let root: URL
    private let lock = NSLock()
    public init(directory: URL) { root = directory }

    public func load(publication: EPUBPublication) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        try validateRoot()
        return try recover(publication).data
    }
    public func save(_ data: Data, publication: EPUBPublication) throws {
        lock.lock(); defer { lock.unlock() }
        try ReaderStateValidation.validate(data, publication: publication)
        try validateRoot()
        let url = try stateURL(publication), previous = try recover(publication)
        if let existing = previous.data, try ReaderStateValidation.revision(data) < ReaderStateValidation.revision(existing) { throw ReaderStateValidation.Failure.staleRevision }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if previous.recovered, FileManager.default.fileExists(atPath: url.path) {
            guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { throw ReaderStateValidation.Failure.invalidState }
            // Preserve damaged evidence before replacing the primary; do not overwrite the valid backup.
            try FileManager.default.copyItem(at: url, to: url.appendingPathExtension("recovery-" + UUID().uuidString))
        } else if let existing = previous.data {
            try existing.write(to: url.appendingPathExtension("bak"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
    private func recover(_ publication: EPUBPublication) throws -> (data: Data?, recovered: Bool) {
        let url = try stateURL(publication), backup = try stateURL(publication).appendingPathExtension("bak")
        let fm = FileManager.default
        let primaryExists = (try? fm.attributesOfItem(atPath: url.path)) != nil
        let backupExists = (try? fm.attributesOfItem(atPath: backup.path)) != nil
        guard primaryExists || backupExists else { return (nil, false) }
        if let data = try? validated(url, publication: publication) { return (data, false) }
        if let data = try? validated(backup, publication: publication) { return (data, true) }
        throw ReaderStateValidation.Failure.invalidState
    }
    private func validateRoot() throws {
        guard root.isFileURL else { throw ReaderStateValidation.Failure.invalidState }
        var path = root.path
        while path != "/" && !path.isEmpty {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                let type = attrs[.type] as? FileAttributeType
                // macOS supplies /var-based temporary directories. Only these fixed system aliases are accepted.
                if type == .typeSymbolicLink {
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                    guard (path == "/var" && target == "private/var") || (path == "/tmp" && target == "private/tmp") else { throw ReaderStateValidation.Failure.invalidState }
                } else if type != .typeDirectory { throw ReaderStateValidation.Failure.invalidState }
            }
            path = (path as NSString).deletingLastPathComponent
        }
    }
    private func stateURL(_ publication: EPUBPublication) throws -> URL {
        guard publication.id.count == 64, publication.id.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ReaderStateValidation.Failure.invalidState }
        return root.appendingPathComponent(publication.id + ".json")
    }
    private func validated(_ url: URL, publication: EPUBPublication) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= ReaderStateValidation.maximumBytes else { throw ReaderStateValidation.Failure.invalidState }
        let data = try Data(contentsOf: url)
        try ReaderStateValidation.validate(data, publication: publication)
        return data
    }
}

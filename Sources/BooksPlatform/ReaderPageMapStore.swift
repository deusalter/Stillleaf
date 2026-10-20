import Foundation
import BooksCore

/// Whole-book screen counts the renderer measured, per book and layout, so a reopened book shows its page count at once.
/// A disposable display cache: it is never reading state, progress or evidence, and any damage means counting again.
public final class ReaderPageMapStore {
    public static let maximumMaps = 12
    public static let maximumKeyLength = 8_192
    public static let maximumCount = 1_000_000
    private static let maximumFileBytes = 4 * 1_024 * 1_024
    private let root: URL
    private let lock = NSLock()
    public init(directory: URL) { root = directory }

    /// Saved maps for this book, most recent first, as JSON objects for the renderer.
    public func load(publication: EPUBPublication) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        guard let url = fileURL(publication),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: url),
              let maps = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return Array(maps.compactMap { Self.validated($0, chapters: publication.spine.count) }.prefix(Self.maximumMaps))
    }

    /// Keeps one finished map (renderer JSON) as the most recent for its layout. Malformed maps are ignored.
    @discardableResult
    public func record(_ data: Data, publication: EPUBPublication) -> Bool {
        guard data.count <= Self.maximumFileBytes, let value = try? JSONSerialization.jsonObject(with: data),
              let map = Self.validated(value, chapters: publication.spine.count), let key = map["key"] as? String else { return false }
        let current = load(publication: publication)
        lock.lock(); defer { lock.unlock() }
        guard let url = fileURL(publication) else { return false }
        let maps = [map] + current.filter { $0["key"] as? String != key }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: Array(maps.prefix(Self.maximumMaps))).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    static func validated(_ value: Any, chapters: Int) -> [String: Any]? {
        guard let map = value as? [String: Any], Set(map.keys) == ["key", "counts"],
              let key = map["key"] as? String, !key.isEmpty, key.utf16.count <= maximumKeyLength,
              let raw = map["counts"] as? [Any], raw.count == chapters, chapters > 0 else { return nil }
        var counts: [Int] = []
        counts.reserveCapacity(raw.count)
        for value in raw {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= 1, number.doubleValue <= Double(maximumCount) else { return nil }
            counts.append(number.intValue)
        }
        return ["key": key, "counts": counts]
    }

    private func fileURL(_ publication: EPUBPublication) -> URL? {
        guard root.isFileURL, publication.id.count == 64, publication.id.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return root.appendingPathComponent(publication.id + ".json")
    }
}

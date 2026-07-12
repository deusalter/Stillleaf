import Foundation
import CoreFoundation

/// Schema 1 bounds shared with Reader/desktop/src/reader-state.cjs.
/// fontSize is a 0.5...3 multiplier, not a percentage.
public enum ReaderStateValidation {
    public static let maximumBytes = 2 * 1_024 * 1_024
    public enum Failure: Error { case invalidState, staleRevision }
    private static let safeInteger = 9_007_199_254_740_991.0
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func integer(_ value: Any?, minimum: Double = 0) -> Bool {
        guard let n = number(value) else { return false }
        return n >= minimum && n <= safeInteger && n.rounded(.towardZero) == n
    }
    private static func text(_ value: Any?, maximum: Int) -> Bool {
        guard let value = value as? String else { return false }; return value.utf16.count <= maximum
    }
    private static func timestamp(_ value: Any?) -> Bool {
        guard text(value, maximum: 64), let value = value as? String else { return false }
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value) != nil
    }
    public static func revision(_ data: Data) throws -> Double {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], integer(value["revision"]), let result = number(value["revision"]) else { throw Failure.invalidState }
        return result
    }
    public static func validate(_ data: Data, publication: EPUBPublication) throws {
        guard data.count <= maximumBytes, publication.id.count == 64, publication.id.allSatisfy({ "0123456789abcdef".contains($0) }),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], number(value["schemaVersion"]) == 1,
              value["editionId"] as? String == publication.id, integer(value["revision"]),
              let bookmarks = value["bookmarks"] as? [[String: Any]], bookmarks.count <= 2000,
              let annotations = value["annotations"] as? [[String: Any]], annotations.count <= 2000,
              let preferences = value["preferences"] as? [String: Any],
              let theme = preferences["theme"] as? String, ["system", "paper", "sepia", "dark"].contains(theme),
              let family = preferences["fontFamily"] as? String, ["publisher", "serif", "sans"].contains(family) else { throw Failure.invalidState }
        for (key, lower, upper) in [("fontSize", 0.5, 3.0), ("lineHeight", 1.0, 3.0), ("measure", 20.0, 120.0)] {
            guard let n = number(preferences[key]), n >= lower, n <= upper else { throw Failure.invalidState }
        }
        for key in ["scroll", "hyphens"] {
            if let value = preferences[key] {
                if key == "hyphens", value is NSNull { continue }
                guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Failure.invalidState }
            }
        }
        if let weight = preferences["fontWeight"], !(weight is NSNull) {
            guard let n = number(weight), n >= 100, n <= 1000 else { throw Failure.invalidState }
        }
        for key in ["letterSpacing", "wordSpacing"] {
            if let value = preferences[key] { guard let n = number(value), n >= 0, n <= 1 else { throw Failure.invalidState } }
        }
        if let alignment = preferences["textAlign"] { guard let alignment = alignment as? String, ["publisher", "start", "justify"].contains(alignment) else { throw Failure.invalidState } }
        if let columns = preferences["columns"] { guard let columns = columns as? String, ["one", "two"].contains(columns) else { throw Failure.invalidState } }
        let paths = Set(publication.resources.map(\.path))
        func locator(_ raw: Any?) -> Bool {
            guard let raw = raw as? [String: Any], let href = raw["href"] as? String, paths.contains(href) else { return false }
            if let type = raw["type"], !text(type, maximum: 128) { return false }
            if let title = raw["title"], !text(title, maximum: 4096) { return false }
            if let locations = raw["locations"] {
                guard let locations = locations as? [String: Any] else { return false }
                for key in ["progression", "totalProgression"] {
                    if let value = locations[key] { guard let n = number(value), n >= 0, n <= 1 else { return false } }
                }
                if let position = locations["position"], !integer(position, minimum: 1) { return false }
                if let fragments = locations["fragments"] {
                    guard let fragments = fragments as? [String], fragments.count <= 20, fragments.allSatisfy({ text($0, maximum: 8192) }) else { return false }
                }
                if let range = locations["domRange"] {
                    guard let range = range as? [String: Any], Set(range.keys).isSubset(of: ["start", "end"]) else { return false }
                    for key in ["start", "end"] {
                        guard let point = range[key] as? [String: Any], Set(point.keys).isSubset(of: ["cssSelector", "textNodeIndex", "charOffset"]), text(point["cssSelector"], maximum: 8192) else { return false }
                        for offset in ["textNodeIndex", "charOffset"] {
                            if let value = point[offset] { guard integer(value), let n = number(value), n <= 10_000_000 else { return false } }
                        }
                    }
                }
                for key in ["cssSelector", "partialCfi"] { if let value = locations[key], !text(value, maximum: 8192) { return false } }
            }
            if let context = raw["text"] {
                guard let context = context as? [String: Any] else { return false }
                for key in ["before", "highlight", "after"] { if let value = context[key], !text(value, maximum: 16384) { return false } }
            }
            return true
        }
        if let position = value["position"], !(position is NSNull), !locator(position) { throw Failure.invalidState }
        for (kind, items) in [("bookmarks", bookmarks), ("annotations", annotations)] {
            var ids = Set<String>()
            for item in items {
                guard let id = item["id"] as? String, !id.isEmpty, text(id, maximum: 128), ids.insert(id).inserted,
                      locator(item["locator"]), timestamp(item["createdAt"]) else { throw Failure.invalidState }
                if kind == "bookmarks" {
                    if let label = item["label"], !(label is NSNull), !text(label, maximum: 4096) { throw Failure.invalidState }
                } else {
                    guard timestamp(item["updatedAt"]) else { throw Failure.invalidState }
                    for (key, maximum) in [("quote", 32768), ("note", 65536), ("color", 64)] {
                        if let value = item[key], !(value is NSNull), !text(value, maximum: maximum) { throw Failure.invalidState }
                    }
                }
            }
        }
    }
}

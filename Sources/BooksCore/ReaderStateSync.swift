import Foundation

/// A book's reading place, bookmarks and highlights across devices. Each device publishes a `Record` for an
/// edition; `merge` turns this device's record and the others' into the state this device should hold.
///
/// The rules: the place is wherever the book was read most recently; bookmarks and highlights from every device
/// are kept, the newer version of a highlight wins, and something removed on one device is removed on all.
/// Appearance (theme, type, size) is never merged: a phone and a Mac want different pages.
public enum ReaderStateSync {
    public struct Record: Equatable {
        public var editionID: String
        /// The reader's own state document (schema 1), as `ReaderStateStore` holds it.
        public var state: Data
        /// When the reader last moved in this book, on whichever device that reading happened.
        public var positionAt: Date?
        public var removedBookmarks: [String: Date]
        public var removedAnnotations: [String: Date]

        public init(editionID: String, state: Data, positionAt: Date?, removedBookmarks: [String: Date] = [:], removedAnnotations: [String: Date] = [:]) {
            self.editionID = editionID; self.state = state; self.positionAt = positionAt
            self.removedBookmarks = removedBookmarks; self.removedAnnotations = removedAnnotations
        }

        /// The file a device writes for this edition.
        public func encoded() throws -> Data {
            guard let state = try JSONSerialization.jsonObject(with: state) as? [String: Any] else { throw ReaderStateValidation.Failure.invalidState }
            let document: [String: Any] = [
                "version": 1, "editionId": editionID, "state": state,
                "positionAt": positionAt.map(ReaderStateSync.text) ?? NSNull(),
                "removedBookmarks": removedBookmarks.mapValues(ReaderStateSync.text),
                "removedAnnotations": removedAnnotations.mapValues(ReaderStateSync.text)
            ]
            return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        }

        /// Reads another device's file. The state inside is checked against the edition when it is merged.
        public static func decode(_ data: Data) throws -> Record {
            guard data.count <= ReaderStateValidation.maximumBytes + 262_144,
                  let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (document["version"] as? NSNumber)?.intValue == 1,
                  let edition = document["editionId"] as? String,
                  let state = document["state"] as? [String: Any] else { throw ReaderStateValidation.Failure.invalidState }
            func dates(_ value: Any?) -> [String: Date] {
                ((value as? [String: String]) ?? [:]).compactMapValues(ReaderStateSync.date)
            }
            return Record(editionID: edition, state: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
                          positionAt: (document["positionAt"] as? String).flatMap(ReaderStateSync.date),
                          removedBookmarks: dates(document["removedBookmarks"]), removedAnnotations: dates(document["removedAnnotations"]))
        }
    }

    public struct Merged: Equatable {
        /// The state this device should now hold, and its place's time.
        public var record: Record
        /// False when this device already held exactly this.
        public var changed: Bool
    }

    /// Nil when there is nothing valid to hold: no local state and no usable copy from another device.
    public static func merge(local: Record?, remotes: [Record], publication: EPUBPublication) -> Merged? {
        func object(_ record: Record) -> [String: Any]? {
            guard record.editionID == publication.id, (try? ReaderStateValidation.validate(record.state, publication: publication)) != nil else { return nil }
            return (try? JSONSerialization.jsonObject(with: record.state)) as? [String: Any]
        }
        let localState = local.flatMap(object)
        let others = remotes.compactMap { record in object(record).map { (record: record, state: $0) } }
        guard localState != nil || !others.isEmpty else { return nil }

        var state: [String: Any]
        var positionAt: Date?
        if let localState {
            state = localState
            positionAt = local?.positionAt
        } else {
            // First time this device sees the book: start from the copy read most recently.
            let newest = others.max { ($0.record.positionAt ?? .distantPast) < ($1.record.positionAt ?? .distantPast) }!
            state = newest.state
            positionAt = newest.record.positionAt
        }
        for other in others {
            guard let at = other.record.positionAt, at > (positionAt ?? .distantPast), let position = other.state["position"] as? [String: Any] else { continue }
            state["position"] = position
            positionAt = at
        }

        var goneBookmarks = local?.removedBookmarks ?? [:], goneAnnotations = local?.removedAnnotations ?? [:]
        for other in others {
            goneBookmarks.merge(other.record.removedBookmarks) { max($0, $1) }
            goneAnnotations.merge(other.record.removedAnnotations) { max($0, $1) }
        }
        func time(_ item: [String: Any], _ key: String) -> Date { (item[key] as? String).flatMap(date) ?? .distantPast }

        var bookmarks = state["bookmarks"] as? [[String: Any]] ?? []
        var bookmarkIDs = Set(bookmarks.compactMap { $0["id"] as? String })
        for other in others {
            for item in other.state["bookmarks"] as? [[String: Any]] ?? [] {
                if let id = item["id"] as? String, bookmarkIDs.insert(id).inserted { bookmarks.append(item) }
            }
        }
        bookmarks.removeAll { item in (item["id"] as? String).flatMap { goneBookmarks[$0] }.map { time(item, "createdAt") <= $0 } ?? false }

        var annotations = state["annotations"] as? [[String: Any]] ?? []
        var annotationIndex: [String: Int] = [:]
        for (index, item) in annotations.enumerated() { if let id = item["id"] as? String { annotationIndex[id] = index } }
        for other in others {
            for item in other.state["annotations"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                if let index = annotationIndex[id] {
                    if time(item, "updatedAt") > time(annotations[index], "updatedAt") { annotations[index] = item }
                } else {
                    annotationIndex[id] = annotations.count
                    annotations.append(item)
                }
            }
        }
        annotations.removeAll { item in (item["id"] as? String).flatMap { goneAnnotations[$0] }.map { time(item, "updatedAt") <= $0 } ?? false }

        // The reader's own limit; the oldest are kept, as the reader refuses to add past it.
        state["bookmarks"] = Array(bookmarks.prefix(2000))
        state["annotations"] = Array(annotations.prefix(2000))

        func comparable(_ value: [String: Any]) -> NSDictionary {
            var copy = value
            copy["revision"] = nil
            return NSDictionary(dictionary: copy)
        }
        let changed = localState.map { !comparable($0).isEqual(comparable(state)) } ?? true
        if changed {
            // Above every revision seen, so the store accepts it and the reader treats it as the newest.
            let revisions = ([localState].compactMap { $0 } + others.map(\.state)).compactMap { ($0["revision"] as? NSNumber)?.doubleValue }
            state["revision"] = (revisions.max() ?? 0) + 1
        }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              (try? ReaderStateValidation.validate(data, publication: publication)) != nil else { return nil }
        return Merged(record: Record(editionID: publication.id, state: data, positionAt: positionAt,
                                     removedBookmarks: goneBookmarks, removedAnnotations: goneAnnotations), changed: changed)
    }

    /// The ids of a state's bookmarks and highlights, and its place as comparable text: what a device remembers
    /// between syncs to notice what its reader removed or moved.
    public static func contents(of state: Data) -> (bookmarks: Set<String>, annotations: Set<String>, position: String?)? {
        guard let object = (try? JSONSerialization.jsonObject(with: state)) as? [String: Any] else { return nil }
        func ids(_ key: String) -> Set<String> { Set((object[key] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }) }
        let position = (object["position"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { String(decoding: $0, as: UTF8.self) }
        return (ids("bookmarks"), ids("annotations"), position)
    }

    static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.string(from: date)
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
}

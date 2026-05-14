import Foundation
import CSQLite

public enum ReadingStoreError: Error, CustomStringConvertible, Equatable {
    case sqlite(String)
    case invalidData(String)
    case conflict(String)

    public var description: String {
        switch self {
        case .sqlite(let message): return "SQLite error: \(message)"
        case .invalidData(let message): return "Invalid reading history: \(message)"
        case .conflict(let message): return "Reading history conflict: \(message)"
        }
    }
}

public final class ReadingStore {
    private struct BookObservation: Codable {
        var previous: BookRecord?
        var current: BookRecord
    }

    private var database: OpaquePointer?
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var effectiveCache: [ReadingInterval]?
    private var intervalIDCache: Set<String>?
    private static let schemaVersion = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        self.url = url
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            if let handle { sqlite3_close(handle) }
            throw ReadingStoreError.sqlite(message)
        }
        database = handle
        do {
            guard sqlite3_busy_timeout(handle, 5_000) == SQLITE_OK else { throw sqliteError(handle) }
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA secure_delete = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try migrate()
            try restrictOwnedDatabasePermissions()
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func archive() throws -> HistoryArchive {
        try Self.readArchive(from: requireDatabase(), decoder: decoder)
    }

    public func effectiveIntervals() throws -> [ReadingInterval] {
        if let effectiveCache { return effectiveCache }
        let snapshot = try archive()
        let intervals = try Self.effectiveIntervals(in: snapshot)
        effectiveCache = intervals
        intervalIDCache = Set((snapshot.intervals + snapshot.corrections.flatMap(\.replacements)).map(\.id))
        return intervals
    }

    public func saveBook(_ book: BookRecord) throws {
        try validate(book: book)
        if let existing: BookRecord = try decodedRow(table: "books", id: book.id) {
            guard Self.substantiveBook(existing) != Self.substantiveBook(book) else { return }
            let detail = String(data: try encode(BookObservation(previous: existing, current: book)), encoding: .utf8)!
            try transaction {
                try upsert(table: "books", id: book.id, payload: try encode(book))
                let event = AuditEvent(date: book.observedAt, kind: "bookMetadataObserved", bookID: book.id, detail: detail)
                try insertUnique(table: "events", id: event.id, payload: try encode(event), value: event)
            }
        } else {
            let detail = String(data: try encode(BookObservation(previous: nil, current: book)), encoding: .utf8)!
            try transaction {
                try upsert(table: "books", id: book.id, payload: try encode(book))
                let event = AuditEvent(date: book.observedAt, kind: "bookMetadataObserved", bookID: book.id, detail: detail)
                try insertUnique(table: "events", id: event.id, payload: try encode(event), value: event)
            }
        }
    }

    public func appendInterval(_ interval: ReadingInterval) throws {
        if let existing: ReadingInterval = try decodedRow(table: "intervals", id: interval.id) {
            guard try canonicallyEqual(existing, interval) else { throw ReadingStoreError.conflict("interval id \(interval.id) already exists") }
            return
        }
        let insertion = try validateEffectiveInsertion(interval)
        try insertInterval(interval)
        effectiveCache?.insert(interval, at: insertion)
        intervalIDCache?.insert(interval.id)
    }

    public func appendEvent(_ event: AuditEvent) throws {
        try Self.validateEvent(event)
        if event.pageTurn != nil || event.completion != nil || event.rating != nil {
            guard let bookID = event.bookID, let _: BookRecord = try decodedRow(table: "books", id: bookID) else {
                throw ReadingStoreError.invalidData("typed event refers to an unknown book")
            }
        }
        if event.pageTurn != nil {
            guard Self.pageEventHasSourceInterval(event, in: try archive()) else {
                throw ReadingStoreError.invalidData("page-turn event does not belong to a recorded session interval")
            }
        }
        try insertUnique(table: "events", id: event.id, payload: try encode(event), value: event)
    }

    public func appendProgress(_ observation: ProgressObservation) throws {
        guard Self.validDate(observation.observedAt), observation.fraction.map({ $0.isFinite && $0 >= 0 && $0 <= 1 }) ?? true else {
            throw ReadingStoreError.invalidData("progress fraction must be between zero and one")
        }
        try insertUnique(table: "progress", id: observation.id, payload: try encode(observation), value: observation)
    }

    public func setGoal(_ goal: GoalChange) throws {
        guard Self.isDayKey(goal.effectiveDay), Self.validDate(goal.createdAt), goal.minutes.isFinite, goal.minutes > 0, goal.minutes <= 1_440,
              goal.pages.map({ $0.isFinite && $0 > 0 && $0 <= 1_000_000 }) ?? true else {
            throw ReadingStoreError.invalidData("goal has an invalid day or duration")
        }
        try insertUnique(table: "goals", id: goal.id, payload: try encode(goal), value: goal)
    }

    public func correct(_ correction: IntervalCorrection) throws {
        var prospective = try archive()
        if let existing = prospective.corrections.first(where: { $0.id == correction.id }) {
            guard try canonicallyEqual(existing, correction) else { throw ReadingStoreError.conflict("correction id \(correction.id) already exists") }
            return
        }
        prospective.corrections.append(correction)
        try Self.validate(prospective)
        try insertUnique(table: "corrections", id: correction.id, payload: try encode(correction), value: correction)
        effectiveCache = try Self.effectiveIntervals(in: prospective)
        intervalIDCache = Set((prospective.intervals + prospective.corrections.flatMap(\.replacements)).map(\.id))
    }

    public func merge(_ merge: BookMerge) throws {
        guard merge.sourceID != merge.targetID, Self.validDate(merge.date) else { throw ReadingStoreError.invalidData("a book cannot be merged into itself or use an invalid date") }
        var snapshot = try archive()
        let ids = Set(snapshot.books.map(\.id))
        guard ids.contains(merge.sourceID), ids.contains(merge.targetID) else {
            throw ReadingStoreError.invalidData("merge refers to an unknown book")
        }
        snapshot.merges.append(merge)
        try Self.validate(snapshot)
        try insertUnique(table: "merges", id: merge.id, payload: try encode(merge), value: merge)
    }

    public func deleteSession(_ sessionID: String) throws {
        guard !sessionID.isEmpty else { return }
        try transaction {
            let snapshot = try archive()
            try materializeDeletion(in: snapshot) { $0.sessionID == sessionID }
            try execute("DELETE FROM events WHERE session_id = ?", bindings: [.text(sessionID)])
            try Self.validate(try archive())
        }
        effectiveCache = nil
        intervalIDCache = nil
        try purgeDeletedPages()
    }

    public func deleteBook(_ bookID: String) throws {
        guard !bookID.isEmpty else { return }
        try transaction {
            let snapshot = try archive()
            try materializeDeletion(in: snapshot) { $0.bookID == bookID }
            try execute("DELETE FROM events WHERE book_id = ?", bindings: [.text(bookID)])
            try execute("DELETE FROM progress WHERE book_id = ?", bindings: [.text(bookID)])
            try execute("DELETE FROM merges WHERE source_id = ? OR target_id = ?", bindings: [.text(bookID), .text(bookID)])
            try execute("DELETE FROM books WHERE id = ?", bindings: [.text(bookID)])
            try Self.validate(try archive())
        }
        effectiveCache = nil
        intervalIDCache = nil
        try purgeDeletedPages()
    }

    public func deleteAll() throws {
        try transaction { try clearAll() }
        effectiveCache = []
        intervalIDCache = []
        try purgeDeletedPages()
    }

    public func exportJSON(to url: URL) throws {
        try rejectOwnedDatabasePath(url)
        let data = try encode(archive())
        try data.write(to: url, options: .atomic)
    }

    public func importJSON(from url: URL) throws {
        let imported = try decoder.decode(HistoryArchive.self, from: Data(contentsOf: url))
        guard imported.version == Self.schemaVersion else {
            throw ReadingStoreError.invalidData("unsupported archive version \(imported.version)")
        }
        try Self.validate(imported)
        let existing = try archive()
        let merged = try Self.merged(existing, imported)
        try Self.validate(merged)
        try transaction { try insertArchive(imported, allowIdentical: true) }
        effectiveCache = try Self.effectiveIntervals(in: merged)
        intervalIDCache = Set((merged.intervals + merged.corrections.flatMap(\.replacements)).map(\.id))
    }

    public func exportCSV(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["intervals.csv", "effective_intervals.csv", "books.csv", "goals.csv", "corrections.csv", "events.csv", "progress.csv"] {
            try rejectOwnedDatabasePath(directory.appendingPathComponent(name))
        }
        let snapshot = try archive()
        let intervalHeader = ["id", "session_id", "book_id", "start", "end", "duration_seconds", "timezone", "mode", "disposition"]
        let intervalRows = snapshot.intervals.map { interval in
            [interval.id, interval.sessionID, interval.bookID, Self.iso8601(interval.start), Self.iso8601(interval.end), String(interval.duration), interval.timezoneID, interval.mode.rawValue, interval.disposition.rawValue]
        }
        try Self.writeCSV(header: intervalHeader, rows: intervalRows, to: directory.appendingPathComponent("intervals.csv"))

        let bookRows = snapshot.books.map { [$0.id, $0.title, $0.author ?? "", $0.source, Self.iso8601($0.observedAt), $0.coverPath ?? "", $0.coverSource ?? "", String($0.trackingExcluded), String($0.sharingExcluded)] }
        try Self.writeCSV(header: ["id", "title", "author", "source", "observed_at", "cover_path", "cover_source", "tracking_excluded", "sharing_excluded"], rows: bookRows, to: directory.appendingPathComponent("books.csv"))

        let dayRows = snapshot.goals.map { [$0.id, $0.effectiveDay, String($0.minutes), $0.pages.map { String($0) } ?? "", Self.iso8601($0.createdAt)] }
        try Self.writeCSV(header: ["id", "effective_day", "minutes", "pages", "created_at"], rows: dayRows, to: directory.appendingPathComponent("goals.csv"))

        let effectiveRows = try effectiveIntervals().map { interval in
            [interval.id, interval.sessionID, interval.bookID, Self.iso8601(interval.start), Self.iso8601(interval.end), String(interval.duration), interval.timezoneID, interval.mode.rawValue, interval.disposition.rawValue]
        }
        try Self.writeCSV(header: intervalHeader, rows: effectiveRows, to: directory.appendingPathComponent("effective_intervals.csv"))

        let correctionRows = snapshot.corrections.map { correction in
            [correction.id, Self.iso8601(correction.createdAt), correction.originalIDs.joined(separator: "|"), correction.replacements.map(\.id).joined(separator: "|"), correction.reason]
        }
        try Self.writeCSV(header: ["id", "created_at", "original_interval_ids", "replacement_interval_ids", "reason"], rows: correctionRows, to: directory.appendingPathComponent("corrections.csv"))

        let eventRows = snapshot.events.map(Self.eventCSVRow)
        try Self.writeCSV(header: ["id", "date", "kind", "book_id", "session_id", "detail", "from_page", "to_page", "pages_read", "visible_pages", "layout_signature", "finished_at", "completion_source", "completion_imported", "rating_state", "rating_value"], rows: eventRows, to: directory.appendingPathComponent("events.csv"))

        let progressRows = snapshot.progress.map { [$0.id, $0.bookID, Self.iso8601($0.observedAt), $0.page.map(String.init) ?? "", $0.totalPages.map(String.init) ?? "", $0.fraction.map { String($0) } ?? "", $0.location ?? "", $0.source, String($0.reliable)] }
        try Self.writeCSV(header: ["id", "book_id", "observed_at", "page", "total_pages", "fraction", "location", "source", "reliable"], rows: progressRows, to: directory.appendingPathComponent("progress.csv"))
    }

    public func backup(to destination: URL) throws {
        try rejectOwnedDatabasePath(destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try backupDatabase(from: requireDatabase(), to: temporary)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func restore(from source: URL) throws {
        try rejectOwnedDatabasePath(source)
        var sourceDB: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let sourceDB else {
            let message = sourceDB.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open backup"
            if let sourceDB { sqlite3_close(sourceDB) }
            throw ReadingStoreError.invalidData(message)
        }
        defer { sqlite3_close(sourceDB) }
        let integrity = try Self.scalarText(sourceDB, sql: "PRAGMA quick_check")
        guard integrity == "ok" else { throw ReadingStoreError.invalidData("backup failed SQLite integrity check") }
        let version = try Self.scalarInt(sourceDB, sql: "PRAGMA user_version")
        guard version == Self.schemaVersion else { throw ReadingStoreError.invalidData("unsupported backup schema version \(version)") }
        let restored = try Self.readArchive(from: sourceDB, decoder: decoder)
        try Self.validate(restored)
        try transaction {
            try clearAll()
            try insertArchive(restored, allowIdentical: false)
        }
        effectiveCache = try Self.effectiveIntervals(in: restored)
        intervalIDCache = Set((restored.intervals + restored.corrections.flatMap(\.replacements)).map(\.id))
        try purgeDeletedPages()
        try restrictOwnedDatabasePermissions()
    }

    // Used by TrackingEngine so a checkpoint fragment and its recovery marker commit together.
    func appendCheckpoint(interval: ReadingInterval?, event: AuditEvent) throws {
        let insertion = try interval.map(validateEffectiveInsertion)
        try transaction {
            if let interval {
                try insertInterval(interval)
            }
            try insertUnique(table: "events", id: event.id, payload: try encode(event), value: event)
        }
        if let interval, let insertion {
            effectiveCache?.insert(interval, at: insertion)
            intervalIDCache?.insert(interval.id)
        }
    }

    private enum Binding { case text(String), double(Double) }

    private func requireDatabase() throws -> OpaquePointer {
        guard let database else { throw ReadingStoreError.sqlite("database is closed") }
        return database
    }

    private func migrate() throws {
        let db = try requireDatabase()
        let version = try Self.scalarInt(db, sql: "PRAGMA user_version")
        guard version <= Self.schemaVersion else { throw ReadingStoreError.invalidData("database schema is newer than this application") }
        if version == 0 {
            try transaction {
                try execute("CREATE TABLE books (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
                try execute("CREATE TABLE intervals (id TEXT PRIMARY KEY NOT NULL, session_id TEXT NOT NULL, book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE, start REAL NOT NULL, end REAL NOT NULL, payload BLOB NOT NULL)")
                try execute("CREATE INDEX intervals_session ON intervals(session_id)")
                try execute("CREATE INDEX intervals_time ON intervals(start, end)")
                try execute("CREATE TABLE corrections (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
                try execute("CREATE TABLE goals (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
                try execute("CREATE TABLE events (id TEXT PRIMARY KEY NOT NULL, book_id TEXT, session_id TEXT, date REAL NOT NULL, payload BLOB NOT NULL)")
                try execute("CREATE INDEX events_session ON events(session_id)")
                try execute("CREATE TABLE progress (id TEXT PRIMARY KEY NOT NULL, book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE, date REAL NOT NULL, payload BLOB NOT NULL)")
                try execute("CREATE TABLE merges (id TEXT PRIMARY KEY NOT NULL, source_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE, target_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE, date REAL NOT NULL, payload BLOB NOT NULL)")
                try execute("PRAGMA user_version = 1")
            }
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        let db = try requireDatabase()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError(db) }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch binding {
            case .text(let value): result = sqlite3_bind_text(statement, position, value, -1, Self.transient)
            case .double(let value): result = sqlite3_bind_double(statement, position, value)
            }
            guard result == SQLITE_OK else { throw sqliteError(db) }
        }
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW { step = sqlite3_step(statement) }
        guard step == SQLITE_DONE else { throw sqliteError(db) }
    }

    private func sqliteError(_ db: OpaquePointer) -> ReadingStoreError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }

    private func canonicallyEqual<T: Codable>(_ lhs: T, _ rhs: T) throws -> Bool {
        try Self.canonicalData(lhs) == Self.canonicalData(rhs)
    }

    private func validate(book: BookRecord) throws {
        guard !book.id.isEmpty, !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, Self.validDate(book.observedAt) else {
            throw ReadingStoreError.invalidData("book id and title are required")
        }
    }

    private func validateEffectiveInsertion(_ interval: ReadingInterval) throws -> Int {
        guard let _: BookRecord = try decodedRow(table: "books", id: interval.bookID) else {
            throw ReadingStoreError.invalidData("interval refers to an unknown book")
        }
        try Self.validateInterval(interval)
        let intervals = try effectiveIntervals()
        guard intervalIDCache?.contains(interval.id) != true else { throw ReadingStoreError.conflict("interval id \(interval.id) already exists") }
        var low = 0
        var high = intervals.count
        while low < high {
            let middle = (low + high) / 2
            if (intervals[middle].start, intervals[middle].end, intervals[middle].id) < (interval.start, interval.end, interval.id) { low = middle + 1 }
            else { high = middle }
        }
        if low > 0, intervals[low - 1].end > interval.start {
            throw ReadingStoreError.invalidData("intervals \(intervals[low - 1].id) and \(interval.id) overlap")
        }
        if low < intervals.count, interval.end > intervals[low].start {
            throw ReadingStoreError.invalidData("intervals \(interval.id) and \(intervals[low].id) overlap")
        }
        return low
    }

    private func upsert(table: String, id: String, payload: Data) throws {
        try execute("INSERT INTO \(table) (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", bindings: [.text(id), .text(payload.base64EncodedString())])
    }

    private func insertInterval(_ interval: ReadingInterval) throws {
        try execute("INSERT INTO intervals (id, session_id, book_id, start, end, payload) VALUES (?, ?, ?, ?, ?, ?)", bindings: [.text(interval.id), .text(interval.sessionID), .text(interval.bookID), .double(interval.start.timeIntervalSince1970), .double(interval.end.timeIntervalSince1970), .text(try encode(interval).base64EncodedString())])
    }

    private func insertUnique<T: Codable & Equatable>(table: String, id: String, payload: Data, value: T) throws {
        if let existing: T = try decodedRow(table: table, id: id) {
            guard try canonicallyEqual(existing, value) else { throw ReadingStoreError.conflict("\(table) id \(id) already exists") }
            return
        }
        switch table {
        case "events":
            let event = value as! AuditEvent
            try execute("INSERT INTO events (id, book_id, session_id, date, payload) VALUES (?, ?, ?, ?, ?)", bindings: [.text(id), .text(event.bookID ?? ""), .text(event.sessionID ?? ""), .double(event.date.timeIntervalSince1970), .text(payload.base64EncodedString())])
        case "progress":
            let progress = value as! ProgressObservation
            try execute("INSERT INTO progress (id, book_id, date, payload) VALUES (?, ?, ?, ?)", bindings: [.text(id), .text(progress.bookID), .double(progress.observedAt.timeIntervalSince1970), .text(payload.base64EncodedString())])
        case "merges":
            let merge = value as! BookMerge
            try execute("INSERT INTO merges (id, source_id, target_id, date, payload) VALUES (?, ?, ?, ?, ?)", bindings: [.text(id), .text(merge.sourceID), .text(merge.targetID), .double(merge.date.timeIntervalSince1970), .text(payload.base64EncodedString())])
        default:
            try execute("INSERT INTO \(table) (id, payload) VALUES (?, ?)", bindings: [.text(id), .text(payload.base64EncodedString())])
        }
    }

    private func decodedRow<T: Decodable>(table: String, id: String) throws -> T? {
        let db = try requireDatabase()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table) WHERE id = ?", -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let text = sqlite3_column_text(statement, 0), let data = Data(base64Encoded: String(cString: text)) else {
            throw ReadingStoreError.invalidData("invalid payload in \(table)")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func insertArchive(_ snapshot: HistoryArchive, allowIdentical: Bool) throws {
        for book in snapshot.books {
            if allowIdentical, let existing: BookRecord = try decodedRow(table: "books", id: book.id) {
                if Self.substantiveBook(existing) == Self.substantiveBook(book) { continue }
                guard book.observedAt > existing.observedAt else {
                    if book.observedAt == existing.observedAt { throw ReadingStoreError.conflict("book id \(book.id) has conflicting metadata at the same observation time") }
                    continue
                }
                try upsert(table: "books", id: book.id, payload: try encode(book))
                let detail = String(data: try encode(BookObservation(previous: existing, current: book)), encoding: .utf8)!
                let event = AuditEvent(date: book.observedAt, kind: "bookMetadataObserved", bookID: book.id, detail: detail)
                try insertUnique(table: "events", id: event.id, payload: try encode(event), value: event)
            } else { try upsert(table: "books", id: book.id, payload: try encode(book)) }
        }
        for interval in snapshot.intervals {
            if allowIdentical, let existing: ReadingInterval = try decodedRow(table: "intervals", id: interval.id) {
                guard try canonicallyEqual(existing, interval) else { throw ReadingStoreError.conflict("interval id \(interval.id) already exists") }
            } else { try insertInterval(interval) }
        }
        for correction in snapshot.corrections { try insertUnique(table: "corrections", id: correction.id, payload: try encode(correction), value: correction) }
        for goal in snapshot.goals { try insertUnique(table: "goals", id: goal.id, payload: try encode(goal), value: goal) }
        for event in snapshot.events { try insertUnique(table: "events", id: event.id, payload: try encode(event), value: event) }
        for progress in snapshot.progress { try insertUnique(table: "progress", id: progress.id, payload: try encode(progress), value: progress) }
        for merge in snapshot.merges { try insertUnique(table: "merges", id: merge.id, payload: try encode(merge), value: merge) }
    }

    private func clearAll() throws {
        for table in ["corrections", "events", "progress", "merges", "intervals", "goals", "books"] { try execute("DELETE FROM \(table)") }
    }

    private func deleteIDs(table: String, ids: Set<String>) throws {
        for id in ids { try execute("DELETE FROM \(table) WHERE id = ?", bindings: [.text(id)]) }
    }

    // Privacy deletion is allowed to rewrite the affected correction lineage. Materializing
    // its surviving effective intervals prevents either resurrection of an original or loss
    // of a sibling produced by the same split, while unrelated correction chains stay intact.
    private func materializeDeletion(in snapshot: HistoryArchive, matches: (ReadingInterval) -> Bool) throws {
        let allIntervals = snapshot.intervals + snapshot.corrections.flatMap(\.replacements)
        var componentIDs = Set(allIntervals.filter(matches).map(\.id))
        var affectedCorrections = Set<String>()
        var changed = true
        while changed {
            changed = false
            for correction in snapshot.corrections where !affectedCorrections.contains(correction.id) {
                let members = Set(correction.originalIDs + correction.replacements.map(\.id))
                if !members.isDisjoint(with: componentIDs) {
                    affectedCorrections.insert(correction.id)
                    let oldCount = componentIDs.count
                    componentIDs.formUnion(members)
                    changed = changed || componentIDs.count != oldCount
                }
            }
        }
        let survivors = try Self.effectiveIntervals(in: snapshot).filter { componentIDs.contains($0.id) && !matches($0) }
        try deleteIDs(table: "corrections", ids: affectedCorrections)
        try deleteIDs(table: "intervals", ids: componentIDs)
        for survivor in survivors { try insertInterval(survivor) }
    }

    private func purgeDeletedPages() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
        try restrictOwnedDatabasePermissions()
    }

    private func restrictOwnedDatabasePermissions() throws {
        for item in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: item) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: item)
        }
    }

    private func rejectOwnedDatabasePath(_ candidate: URL) throws {
        let owned = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let candidateIdentity = Self.fileIdentity(candidate)
        for item in owned {
            if candidatePath == item.standardizedFileURL.resolvingSymlinksInPath().path {
                throw ReadingStoreError.invalidData("output path is owned by the live database")
            }
            if let candidateIdentity, let ownedIdentity = Self.fileIdentity(item), candidateIdentity == ownedIdentity {
                throw ReadingStoreError.invalidData("output path resolves to the live database")
            }
        }
    }

    private static func fileIdentity(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device.uint64Value):\(inode.uint64Value)"
    }

    private func backupDatabase(from source: OpaquePointer, to destination: URL) throws {
        var target: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let target else {
            let message = target.map { String(cString: sqlite3_errmsg($0)) } ?? "could not create backup"
            let code = target.map { sqlite3_extended_errcode($0) } ?? -1
            if let target { sqlite3_close(target) }
            throw ReadingStoreError.sqlite("could not create backup at \(destination.path): \(message) (\(code))")
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else { throw sqliteError(target) }
        let result = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw ReadingStoreError.sqlite("backup step \(result); source: \(String(cString: sqlite3_errmsg(source))); destination: \(String(cString: sqlite3_errmsg(target)))")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let journalResult = sqlite3_exec(target, "PRAGMA journal_mode=DELETE", nil, nil, &errorMessage)
        defer { if let errorMessage { sqlite3_free(errorMessage) } }
        guard journalResult == SQLITE_OK else {
            throw ReadingStoreError.sqlite(errorMessage.map { String(cString: $0) } ?? "could not finalize backup")
        }
    }

    private static func readArchive(from db: OpaquePointer, decoder: JSONDecoder) throws -> HistoryArchive {
        var result = HistoryArchive()
        result.books = try readRows(db, table: "books", decoder: decoder)
        result.intervals = try readRows(db, table: "intervals", decoder: decoder)
        result.corrections = try readRows(db, table: "corrections", decoder: decoder)
        result.goals = try readRows(db, table: "goals", decoder: decoder)
        result.events = try readRows(db, table: "events", decoder: decoder)
        result.progress = try readRows(db, table: "progress", decoder: decoder)
        result.merges = try readRows(db, table: "merges", decoder: decoder)
        return result
    }

    private static func readRows<T: Decodable>(_ db: OpaquePointer, table: String, decoder: JSONDecoder) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table) ORDER BY rowid", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReadingStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0), let data = Data(base64Encoded: String(cString: text)) else {
                throw ReadingStoreError.invalidData("invalid payload in \(table)")
            }
            rows.append(try decoder.decode(T.self, from: data))
        }
        return rows
    }

    private static func effectiveIntervals(in archive: HistoryArchive) throws -> [ReadingInterval] {
        var active = Dictionary(uniqueKeysWithValues: archive.intervals.map { ($0.id, $0) })
        var seen = Set(active.keys)
        for correction in archive.corrections {
            guard !correction.originalIDs.isEmpty, Set(correction.originalIDs).count == correction.originalIDs.count else {
                throw ReadingStoreError.invalidData("correction \(correction.id) has no unique originals")
            }
            for id in correction.originalIDs {
                guard active.removeValue(forKey: id) != nil else { throw ReadingStoreError.invalidData("correction \(correction.id) refers to inactive interval \(id)") }
            }
            for replacement in correction.replacements {
                guard !seen.contains(replacement.id), active[replacement.id] == nil else { throw ReadingStoreError.invalidData("duplicate replacement interval id \(replacement.id)") }
                active[replacement.id] = replacement
                seen.insert(replacement.id)
            }
        }
        return active.values.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
    }

    private static func validate(_ archive: HistoryArchive) throws {
        guard archive.version == schemaVersion else { throw ReadingStoreError.invalidData("unsupported archive version") }
        guard validDate(archive.exportedAt) else { throw ReadingStoreError.invalidData("archive export date is outside the supported range") }
        try unique(archive.books.map(\.id), label: "book")
        try unique(archive.intervals.map(\.id), label: "interval")
        try unique(archive.corrections.map(\.id), label: "correction")
        try unique(archive.goals.map(\.id), label: "goal")
        try unique(archive.events.map(\.id), label: "event")
        try unique(archive.progress.map(\.id), label: "progress")
        try unique(archive.merges.map(\.id), label: "merge")
        let books = Set(archive.books.map(\.id))
        for book in archive.books where book.id.isEmpty || book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !validDate(book.observedAt) { throw ReadingStoreError.invalidData("book id, title, and observation date are required") }
        for interval in archive.intervals + archive.corrections.flatMap(\.replacements) {
            guard books.contains(interval.bookID) else { throw ReadingStoreError.invalidData("interval \(interval.id) refers to an unknown book") }
            try validateInterval(interval)
        }
        for correction in archive.corrections where !validDate(correction.createdAt) { throw ReadingStoreError.invalidData("invalid correction date \(correction.id)") }
        for goal in archive.goals where !isDayKey(goal.effectiveDay) || !validDate(goal.createdAt) || !goal.minutes.isFinite || goal.minutes <= 0 || goal.minutes > 1_440 || !(goal.pages.map { $0.isFinite && $0 > 0 && $0 <= 1_000_000 } ?? true) { throw ReadingStoreError.invalidData("invalid goal \(goal.id)") }
        for event in archive.events {
            try validateEvent(event)
            if (event.pageTurn != nil || event.completion != nil || event.rating != nil), event.bookID.map({ books.contains($0) }) != true {
                throw ReadingStoreError.invalidData("typed event \(event.id) refers to an unknown book")
            }
            if event.pageTurn != nil, !pageEventHasSourceInterval(event, in: archive) {
                throw ReadingStoreError.invalidData("page-turn event \(event.id) has no source session interval")
            }
        }
        for progress in archive.progress where !books.contains(progress.bookID) || !validDate(progress.observedAt) || !(progress.fraction.map { $0.isFinite && $0 >= 0 && $0 <= 1 } ?? true) { throw ReadingStoreError.invalidData("invalid progress \(progress.id)") }
        for merge in archive.merges where merge.sourceID == merge.targetID || !books.contains(merge.sourceID) || !books.contains(merge.targetID) || !validDate(merge.date) { throw ReadingStoreError.invalidData("invalid merge \(merge.id)") }
        let effective = try effectiveIntervals(in: archive)
        for pair in zip(effective, effective.dropFirst()) where pair.0.end > pair.1.start {
            throw ReadingStoreError.invalidData("intervals \(pair.0.id) and \(pair.1.id) overlap")
        }
    }

    private static func unique(_ ids: [String], label: String) throws {
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { throw ReadingStoreError.invalidData("duplicate or empty \(label) id") }
    }

    private static func validateInterval(_ interval: ReadingInterval) throws {
        let wallSpan = interval.end.timeIntervalSince(interval.start)
        guard !interval.id.isEmpty, !interval.sessionID.isEmpty,
              validDate(interval.start), validDate(interval.end), wallSpan > 0,
              interval.duration.isFinite, interval.duration > 0,
              interval.duration <= 366 * 86_400, interval.duration <= wallSpan + 2,
              TimeZone(identifier: interval.timezoneID) != nil else { throw ReadingStoreError.invalidData("invalid interval \(interval.id)") }
    }

    private static func validateEvent(_ event: AuditEvent) throws {
        guard validDate(event.date) else { throw ReadingStoreError.invalidData("invalid event date \(event.id)") }
        let typedPayloadCount = [event.pageTurn != nil, event.completion != nil, event.rating != nil].filter { $0 }.count
        guard typedPayloadCount <= 1 else { throw ReadingStoreError.invalidData("event \(event.id) has multiple typed payloads") }
        if let evidence = event.pageTurn {
            guard event.kind == "pageTurn", event.bookID?.isEmpty == false, event.sessionID?.isEmpty == false,
                  PageTurnTracker.valid(evidence) else {
                throw ReadingStoreError.invalidData("invalid page-turn event \(event.id)")
            }
        } else if event.kind == "pageTurn" {
            throw ReadingStoreError.invalidData("page-turn event \(event.id) has no typed evidence")
        } else if let completion = event.completion {
            let source = completion.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard event.kind == "bookCompleted", event.bookID?.isEmpty == false, event.sessionID == nil,
                  !source.isEmpty, source.count <= 128,
                  !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  completion.finishedAt.map({ validDate($0) && $0 <= event.date }) ?? true else {
                throw ReadingStoreError.invalidData("invalid book-completion event \(event.id)")
            }
        } else if event.kind == "bookCompleted" {
            throw ReadingStoreError.invalidData("book-completion event \(event.id) has no typed evidence")
        } else if let rating = event.rating {
            guard event.kind == "bookRated", event.bookID?.isEmpty == false, event.sessionID == nil,
                  validRating(rating.value) else {
                throw ReadingStoreError.invalidData("invalid book-rating event \(event.id)")
            }
        } else if event.kind == "bookRated" {
            throw ReadingStoreError.invalidData("book-rating event \(event.id) has no typed evidence")
        }
    }

    private static func validRating(_ value: Double?) -> Bool {
        guard let value else { return true }
        guard value.isFinite, value >= 0, value <= 5 else { return false }
        return abs(value * 4 - (value * 4).rounded()) < 0.000_000_1
    }

    private static func pageEventHasSourceInterval(_ event: AuditEvent, in archive: HistoryArchive) -> Bool {
        guard event.pageTurn != nil, let bookID = event.bookID, let sessionID = event.sessionID else { return false }
        return (archive.intervals + archive.corrections.flatMap(\.replacements)).contains { interval in
            interval.bookID == bookID && interval.sessionID == sessionID && interval.mode == .automatic
                && abs(event.date.timeIntervalSince(interval.end)) <= 0.001
        }
    }

    private static func merged(_ lhs: HistoryArchive, _ rhs: HistoryArchive) throws -> HistoryArchive {
        var result = lhs
        var books = Dictionary(uniqueKeysWithValues: lhs.books.map { ($0.id, $0) })
        for imported in rhs.books {
            guard let existing = books[imported.id] else { books[imported.id] = imported; continue }
            if substantiveBook(existing) == substantiveBook(imported) { continue }
            if imported.observedAt > existing.observedAt { books[imported.id] = imported }
            else if imported.observedAt == existing.observedAt { throw ReadingStoreError.conflict("book id \(imported.id) has conflicting metadata at the same observation time") }
        }
        result.books = books.values.sorted { $0.id < $1.id }
        result.intervals = try mergeRows(lhs.intervals, rhs.intervals, id: \.id, label: "interval")
        result.corrections = try mergeRows(lhs.corrections, rhs.corrections, id: \.id, label: "correction")
        result.goals = try mergeRows(lhs.goals, rhs.goals, id: \.id, label: "goal")
        result.events = try mergeRows(lhs.events, rhs.events, id: \.id, label: "event")
        result.progress = try mergeRows(lhs.progress, rhs.progress, id: \.id, label: "progress")
        result.merges = try mergeRows(lhs.merges, rhs.merges, id: \.id, label: "merge")
        return result
    }

    private static func mergeRows<T: Codable & Equatable>(_ lhs: [T], _ rhs: [T], id: KeyPath<T, String>, label: String) throws -> [T] {
        var result = lhs
        var positions = Dictionary(uniqueKeysWithValues: lhs.enumerated().map { ($0.element[keyPath: id], $0.offset) })
        for row in rhs {
            let key = row[keyPath: id]
            if let position = positions[key] {
                guard try canonicalData(result[position]) == canonicalData(row) else { throw ReadingStoreError.conflict("\(label) id \(key) has different content") }
            } else {
                positions[key] = result.count
                result.append(row)
            }
        }
        return result
    }

    private static func scalarInt(_ db: OpaquePointer, sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ReadingStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ReadingStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func scalarText(_ db: OpaquePointer, sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ReadingStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw ReadingStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        return String(cString: text)
    }

    private static func isDayKey(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }

    private static func validDate(_ date: Date) -> Bool {
        let value = date.timeIntervalSince1970
        return value.isFinite && value >= -2_208_988_800 && value <= 7_258_118_400 // 1900-01-01 through 2200-01-01 UTC.
    }

    // Compare the serialized form rather than Date's bits: decoding a millisecond Double can
    // move Date by one ULP, while re-encoding it produces the same durable JSON representation.
    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    private static func substantiveBook(_ book: BookRecord) -> String {
        [book.title, book.author ?? "", book.source, book.coverPath ?? "", book.coverSource ?? "", String(book.trackingExcluded), String(book.sharingExcluded)].joined(separator: "\u{1f}")
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func eventCSVRow(_ event: AuditEvent) -> [String] {
        var row = [event.id, iso8601(event.date), event.kind, event.bookID ?? "", event.sessionID ?? "", event.detail]
        if let page = event.pageTurn {
            row += [String(page.fromPage), String(page.toPage), String(page.pagesRead), String(page.visiblePages), page.layoutSignature]
        } else { row += ["", "", "", "", ""] }
        if let completion = event.completion {
            row += [completion.finishedAt.map(iso8601) ?? "", completion.source, String(completion.imported)]
        } else { row += ["", "", ""] }
        if let rating = event.rating {
            row += [rating.value == nil ? "clear" : "set", rating.value.map { String($0) } ?? ""]
        } else { row += ["", ""] }
        return row
    }

    private static func writeCSV(header: [String], rows: [[String]], to url: URL) throws {
        let all = [header] + rows
        let text = all.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
        try text.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

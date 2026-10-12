import Foundation
import CSQLite

/// Rows decoded by earlier full reads, by table and rowid. A full read still scans every stored
/// payload, but decodes a row again only when its bytes changed, so the reads that follow each save
/// cost a scan of the history rather than a JSON decode of all of it.
final class DecodedRowCache: @unchecked Sendable {
    private struct Entry {
        let payload: Data
        let value: Any
    }

    private var tables: [String: [Int64: Entry]] = [:]
    private let lock = NSLock()

    func rows<T: Decodable>(_ db: OpaquePointer, table: String, decoder: JSONDecoder) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rowid, payload FROM \(table) ORDER BY rowid", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReadingStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let previous = tables[table] ?? [:]
        var current: [Int64: Entry] = [:]
        current.reserveCapacity(previous.count)
        var rows: [T] = []
        rows.reserveCapacity(previous.count)
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let rowid = sqlite3_column_int64(statement, 0)
            guard let text = sqlite3_column_text(statement, 1) else {
                throw ReadingStoreError.invalidData("invalid payload in \(table)")
            }
            let count = Int(sqlite3_column_bytes(statement, 1))
            if count > 0, let cached = previous[rowid], cached.payload.count == count,
               cached.payload.withUnsafeBytes({ memcmp($0.baseAddress!, text, count) == 0 }),
               let value = cached.value as? T {
                rows.append(value)
                current[rowid] = cached
            } else {
                guard let data = Data(base64Encoded: String(cString: text)) else {
                    throw ReadingStoreError.invalidData("invalid payload in \(table)")
                }
                let value = try decoder.decode(T.self, from: data)
                rows.append(value)
                current[rowid] = Entry(payload: Data(bytes: text, count: count), value: value)
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ReadingStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        tables[table] = current
        return rows
    }

    /// One cache per database file for the read-only snapshots taken off the main thread.
    static func shared(for url: URL) -> DecodedRowCache {
        sharedLock.lock(); defer { sharedLock.unlock() }
        let key = url.standardizedFileURL.path
        if let cache = shared[key] { return cache }
        let cache = DecodedRowCache()
        shared[key] = cache
        return cache
    }

    private static var shared: [String: DecodedRowCache] = [:]
    private static let sharedLock = NSLock()
}

import Foundation
import CSQLite
import BooksCore

public enum BooksAccessError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}

/// Private, version-dependent metadata adapter. Never opens a Books database for writing.
public final class BooksCatalog {
    public let documents: URL
    public init(documents: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.apple.iBooksX/Data/Documents")) { self.documents = documents }
    public func databaseURL() throws -> URL {
        let folder = documents.appendingPathComponent("BKLibrary", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix("BKLibrary-") }
        guard files.count == 1, let file = files.first else { throw BooksAccessError.unavailable("Books catalog is missing or ambiguous. Manual tracking remains available.") }
        return file
    }
    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let path = try databaseURL().path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle = db else {
            if let db = db { sqlite3_close(db) }
            throw BooksAccessError.unavailable("Books catalog cannot be read. Check macOS access permissions.")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 250)
        return try body(handle)
    }
    public func columns() throws -> Set<String> {
        try withDatabase { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(ZBKLIBRARYASSET)", -1, &statement, nil) == SQLITE_OK else { throw BooksAccessError.unavailable("Unrecognized Books catalog schema.") }
            defer { sqlite3_finalize(statement) }
            var values = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW { if let p = sqlite3_column_text(statement, 1) { values.insert(String(cString: p)) } }
            return values
        }
    }
    public func lookup(documentURL: URL) throws -> (book: BookRecord, assetURL: URL, progress: ProgressObservation?)? {
        guard documentURL.isFileURL else { return nil }
        let fields = try columns()
        guard Set(["ZASSETID", "ZTITLE", "ZAUTHOR", "ZPATH"]).isSubset(of: fields) else { throw BooksAccessError.unavailable("This Books catalog schema is unsupported; automatic identity matching is paused.") }
        return try withDatabase { db in
            let progressColumn = fields.contains("ZREADINGPROGRESS") ? "ZREADINGPROGRESS" : "NULL"
            let pagesColumn = fields.contains("ZPAGECOUNT") ? "ZPAGECOUNT" : "NULL"
            let sql = "SELECT ZASSETID,ZTITLE,ZAUTHOR,ZPATH,\(progressColumn),\(pagesColumn) FROM ZBKLIBRARYASSET WHERE ZPATH = ? OR ZPATH = ? LIMIT 2"
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw BooksAccessError.unavailable("Books metadata query failed.") }
            defer { sqlite3_finalize(s) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(s, 1, documentURL.standardizedFileURL.path, -1, transient)
            sqlite3_bind_text(s, 2, documentURL.absoluteString, -1, transient)
            guard sqlite3_step(s) == SQLITE_ROW else { return nil }
            func string(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
            guard let id = string(0), !id.isEmpty, let title = string(1), let path = string(3) else { return nil }
            let book = BookRecord(id: "apple-books:\(id)", title: title, author: string(2), source: "Books catalog / exact AXDocument path")
            let fraction: Double? = sqlite3_column_type(s, 4) == SQLITE_NULL ? nil : sqlite3_column_double(s, 4)
            let pages: Int? = sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, 5))
            let observation = ProgressObservation(bookID: book.id, totalPages: pages.flatMap { $0 > 0 ? $0 : nil }, fraction: fraction.flatMap { (0...1).contains($0) ? $0 : nil }, source: "Books catalog (saved value; freshness unknown)", reliable: false)
            guard sqlite3_step(s) == SQLITE_DONE else { throw BooksAccessError.unavailable("More than one Books asset matches this document. Automatic tracking paused.") }
            let assetURL = path.hasPrefix("file:") ? URL(string: path)! : URL(fileURLWithPath: path)
            return (book, assetURL, observation)
        }
    }
}

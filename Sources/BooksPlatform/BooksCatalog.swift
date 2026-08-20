import Foundation
import CSQLite
import BooksCore

public enum BooksAccessError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}

public struct CatalogFinishedBook {
    public var book: BookRecord
    public var finishedAt: Date?
    public var assetURL: URL?
    public init(book: BookRecord, finishedAt: Date?, assetURL: URL?) {
        self.book = book; self.finishedAt = finishedAt; self.assetURL = assetURL
    }
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
    /// The explicit finished flag and its saved date are completion metadata,
    /// never evidence of past reading duration, page counts, or current progress.
    public func finishedBooks(now: Date = Date()) throws -> [CatalogFinishedBook] {
        let fields = try columns()
        guard Set(["ZASSETID", "ZTITLE", "ZAUTHOR", "ZISFINISHED", "ZDATEFINISHED"]).isSubset(of: fields) else {
            throw BooksAccessError.unavailable("This Books catalog does not expose a supported finished-book timeline.")
        }
        return try withDatabase { db in
            let path = fields.contains("ZPATH") ? "ZPATH" : "NULL"
            var statement: OpaquePointer?
            let sql = "SELECT ZASSETID,ZTITLE,ZAUTHOR,ZDATEFINISHED,\(path) FROM ZBKLIBRARYASSET WHERE ZISFINISHED = 1 LIMIT 10001"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw BooksAccessError.unavailable("The Books finished timeline could not be read.")
            }
            defer { sqlite3_finalize(statement) }
            var results: [CatalogFinishedBook] = []
            var identifiers = Set<String>()
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                func string(_ index: Int32) -> String? { sqlite3_column_text(statement, index).map { String(cString: $0) } }
                guard let id = string(0), !id.isEmpty, let title = string(1), !title.isEmpty,
                      identifiers.insert(id).inserted, results.count < 10_000 else {
                    throw BooksAccessError.unavailable("The Books finished timeline contains ambiguous entries or exceeds the supported size.")
                }
                let seconds = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
                let date = Self.completionDate(referenceSeconds: seconds, now: now)
                let asset = string(4).flatMap(BooksCapture.documentURL)
                let book = BookRecord(id: "apple-books:\(id)", title: title, author: string(2), source: "Apple Books finished timeline")
                results.append(CatalogFinishedBook(book: book, finishedAt: date, assetURL: asset))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw BooksAccessError.unavailable("The Books finished timeline query was interrupted.") }
            return results
        }
    }

    static func completionDate(referenceSeconds: Double?, now: Date) -> Date? {
        guard let seconds = referenceSeconds, seconds.isFinite, seconds > 0 else { return nil }
        let date = Date(timeIntervalSinceReferenceDate: seconds)
        guard date <= now else { return nil }
        return date
    }
    /// Used only after the focused window passes the Books 8 reader-structure check.
    /// Titles select a unique local EPUB; stable asset IDs continue to own all history.
    func lookup(readerTitle: String) throws -> (book: BookRecord, assetURL: URL, progress: ProgressObservation?)? {
        guard !readerTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let fields = try columns()
        guard Set(["ZASSETID", "ZTITLE", "ZAUTHOR", "ZPATH"]).isSubset(of: fields) else {
            throw BooksAccessError.unavailable("This Books catalog schema is unsupported; automatic identity matching is paused.")
        }
        let path: String? = try withDatabase { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT ZPATH FROM ZBKLIBRARYASSET WHERE ZTITLE = ? LIMIT 2", -1, &statement, nil) == SQLITE_OK else {
                throw BooksAccessError.unavailable("Books metadata query failed.")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, readerTitle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let path = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw BooksAccessError.unavailable("More than one Books edition has this title. Use manual reading to choose the book; automatic tracking is paused.")
            }
            return path
        }
        guard let path, let url = BooksCapture.documentURL(path), url.pathExtension.lowercased() == "epub",
              FileManager.default.fileExists(atPath: url.path), var match = try lookup(documentURL: url),
              match.book.title == readerTitle else { return nil }
        match.book.source = "Books catalog / Books 8.0 structural reader inference and unique title"
        return match
    }

    /// Where Apple Books keeps one asset on disk. Read-only; the file itself is never changed.
    public func assetURL(forAssetID assetID: String) throws -> URL? {
        guard !assetID.isEmpty else { return nil }
        let fields = try columns()
        guard Set(["ZASSETID", "ZPATH"]).isSubset(of: fields) else { throw BooksAccessError.unavailable("This Books catalog does not expose book locations.") }
        return try withDatabase { db in
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT ZPATH FROM ZBKLIBRARYASSET WHERE ZASSETID = ? LIMIT 2", -1, &s, nil) == SQLITE_OK else { throw BooksAccessError.unavailable("Books metadata query failed.") }
            defer { sqlite3_finalize(s) }
            sqlite3_bind_text(s, 1, assetID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(s) == SQLITE_ROW, let text = sqlite3_column_text(s, 0) else { return nil }
            let path = String(cString: text)
            guard sqlite3_step(s) == SQLITE_DONE, !path.isEmpty else { return nil }
            return path.hasPrefix("file:") ? URL(string: path) : path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
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

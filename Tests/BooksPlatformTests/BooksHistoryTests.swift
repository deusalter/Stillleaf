import XCTest
import Foundation
import CSQLite
@testable import BooksPlatform

final class BooksHistoryTests: XCTestCase {
    func testExplicitFinishedFlagAndReferenceEpochWithoutInventedDates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("BKLibrary")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("BKLibrary-test.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        }
        try execute("CREATE TABLE ZBKLIBRARYASSET (ZASSETID TEXT,ZTITLE TEXT,ZAUTHOR TEXT,ZISFINISHED INTEGER,ZDATEFINISHED REAL,ZREADINGPROGRESS REAL)")
        try execute("INSERT INTO ZBKLIBRARYASSET VALUES ('a','Finished','Author',1,700000000,0.03),('b','Unknown','Author',1,NULL,1),('c','Not finished','Author',0,700000000,1),('d','Future','Author',1,900000000,1)")
        let catalog = BooksCatalog(documents: root)
        let entries = try catalog.finishedBooks(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertEqual(Set(entries.map { $0.book.id }), ["apple-books:a", "apple-books:b", "apple-books:d"])
        XCTAssertEqual(entries.first { $0.book.id == "apple-books:a" }?.finishedAt, Date(timeIntervalSinceReferenceDate: 700_000_000))
        XCTAssertNil(entries.first { $0.book.id == "apple-books:b" }?.finishedAt)
        XCTAssertNil(entries.first { $0.book.id == "apple-books:d" }?.finishedAt)
        XCTAssertTrue(entries.allSatisfy { $0.assetURL == nil })
        try execute("INSERT INTO ZBKLIBRARYASSET VALUES ('a','Duplicate','Author',1,700000000,1)")
        XCTAssertThrowsError(try catalog.finishedBooks())
        try execute("DROP TABLE ZBKLIBRARYASSET")
        try execute("CREATE TABLE ZBKLIBRARYASSET (ZASSETID TEXT,ZTITLE TEXT)")
        XCTAssertThrowsError(try catalog.finishedBooks())
    }

    func testInvalidCompletionDatesStayUnknown() {
        for seconds: Double? in [nil, 0, -1, .infinity, .nan, 900_000_000] {
            XCTAssertNil(BooksCatalog.completionDate(referenceSeconds: seconds, now: Date(timeIntervalSinceReferenceDate: 800_000_000)))
        }
    }
}

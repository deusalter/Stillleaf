import XCTest
import Foundation
import CSQLite
@testable import BooksPlatform

final class BooksAdapterTests: XCTestCase {
    func testDocumentURLsRejectNonFileValues() {
        XCTAssertNil(BooksCapture.documentURL("A book title"))
        XCTAssertNil(BooksCapture.documentURL("https://example.com/book.epub"))
        XCTAssertEqual(BooksCapture.documentURL("file:///tmp/Example%20Book.epub")?.path, "/tmp/Example Book.epub")
    }
    func testCoverTraversalIsRejected() {
        let root = URL(fileURLWithPath: "/tmp/synthetic.epub")
        XCTAssertNil(CoverCache.safeChild("../private.jpg", root: root))
        XCTAssertNil(CoverCache.safeChild("/private.jpg", root: root))
        XCTAssertNotNil(CoverCache.safeChild("OEBPS/cover.jpg", root: root))
    }
    func testExactIdentityRequiresUniquePathAndRejectsUnknownSchema() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("BKLibrary")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("BKLibrary-test.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ZBKLIBRARYASSET (ZASSETID TEXT,ZTITLE TEXT,ZAUTHOR TEXT,ZPATH TEXT,ZREADINGPROGRESS REAL,ZPAGECOUNT INTEGER)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO ZBKLIBRARYASSET VALUES ('edition-a','Synthetic book','Author','/tmp/a.epub',0.3,200)", nil, nil, nil), SQLITE_OK)
        let catalog = BooksCatalog(documents: root)
        let match = try XCTUnwrap(catalog.lookup(documentURL: URL(fileURLWithPath: "/tmp/a.epub")))
        XCTAssertEqual(match.book.id, "apple-books:edition-a")
        XCTAssertFalse(try XCTUnwrap(match.progress).reliable)
        XCTAssertNil(try catalog.lookup(documentURL: URL(fileURLWithPath: "/tmp/other.epub")))
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO ZBKLIBRARYASSET VALUES ('edition-b','Synthetic book','Author','/tmp/a.epub',0.1,300)", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try catalog.lookup(documentURL: URL(fileURLWithPath: "/tmp/a.epub")))
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE ZBKLIBRARYASSET", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try catalog.lookup(documentURL: URL(fileURLWithPath: "/tmp/a.epub")))
    }
}

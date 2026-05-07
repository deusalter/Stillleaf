import XCTest
import Foundation
import CSQLite
@testable import BooksPlatform

final class BooksReaderTests: XCTestCase {
    private var observedReader: BooksReaderEvidence {
        BooksReaderEvidence(booksVersion: "8.0", identifier: "SceneWindow", role: "AXWindow", subrole: "AXStandardWindow",
            minimized: false, modal: false, webAreaCount: 1, visibleReaderWebAreaCount: 1,
            hasLibraryNavigation: false, inspectionComplete: true, pageNavigationToken: "books8-page:52")
    }

    func testObservedBooksReaderRequiresEveryStructuralGuard() {
        XCTAssertTrue(observedReader.permitsUniqueTitleMatch)
        let mutations: [(inout BooksReaderEvidence) -> Void] = [
            { $0.booksVersion = "8.1" }, { $0.identifier = nil }, { $0.role = "AXGroup" },
            { $0.subrole = "AXDialog" }, { $0.minimized = true }, { $0.modal = true },
            { $0.webAreaCount = 0; $0.visibleReaderWebAreaCount = 0 },
            { $0.webAreaCount = 2; $0.visibleReaderWebAreaCount = 1 },
            { $0.visibleReaderWebAreaCount = 0 },
            { $0.hasLibraryNavigation = true }, { $0.inspectionComplete = false }
        ]
        for mutate in mutations {
            var evidence = observedReader; mutate(&evidence)
            XCTAssertFalse(evidence.permitsUniqueTitleMatch)
        }
    }

    func testReaderAcceptsOneOrTwoMatchingVisibleWebAreasOnly() {
        var evidence = observedReader
        evidence.webAreaCount = 1; evidence.visibleReaderWebAreaCount = 1
        XCTAssertTrue(evidence.permitsUniqueTitleMatch)
        evidence.webAreaCount = 2; evidence.visibleReaderWebAreaCount = 2
        XCTAssertTrue(evidence.permitsUniqueTitleMatch)
        evidence.webAreaCount = 3; evidence.visibleReaderWebAreaCount = 3
        XCTAssertFalse(evidence.permitsUniqueTitleMatch)
        evidence.webAreaCount = 2; evidence.visibleReaderWebAreaCount = 1
        XCTAssertFalse(evidence.permitsUniqueTitleMatch)
    }

    func testPageNavigationTokenAcceptsOnlyTheObservedEnglishFormat() {
        XCTAssertEqual(BooksPageNavigationToken.parse(description: "Page 52"), "books8-page:52")
        XCTAssertEqual(BooksPageNavigationToken.parse(description: "Page 00052"), "books8-page:52")

        let rejected: [String?] = [
            nil, "", "Page ", "Page 0", "Page -1", "page 52", "Page\t52", "Page 52\n",
            "Page 52 of 300", "Chapter Page 52", "Page fifty-two", "Page ５２", "Page 1234567890",
            "Page 52\u{0000}Hidden prose", "Page 52\u{202E}"
        ]
        for description in rejected {
            XCTAssertNil(BooksPageNavigationToken.parse(description: description), "Unexpectedly accepted \(String(describing: description))")
        }
    }

    func testUniqueTitleFallbackPreservesAssetIdentityAndRejectsAmbiguity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("BKLibrary")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let epub = root.appendingPathComponent("fixture.epub")
        try Data().write(to: epub)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("BKLibrary-test.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        }
        let safePath = epub.path.replacingOccurrences(of: "'", with: "''")
        try execute("CREATE TABLE ZBKLIBRARYASSET (ZASSETID TEXT,ZTITLE TEXT,ZAUTHOR TEXT,ZPATH TEXT)")
        try execute("INSERT INTO ZBKLIBRARYASSET VALUES ('edition-a','Synthetic Reading','Author','\(safePath)')")
        let catalog = BooksCatalog(documents: root)
        let match = try XCTUnwrap(catalog.lookup(readerTitle: "Synthetic Reading"))
        XCTAssertEqual(match.book.id, "apple-books:edition-a")
        XCTAssertTrue(match.book.source.contains("inference"))
        XCTAssertFalse(try XCTUnwrap(match.progress).reliable)
        XCTAssertNil(try catalog.lookup(readerTitle: "Synthetic"))
        XCTAssertNil(try catalog.lookup(readerTitle: ""))
        try execute("UPDATE ZBKLIBRARYASSET SET ZTITLE='Renamed Reading'")
        XCTAssertEqual(try catalog.lookup(readerTitle: "Renamed Reading")?.book.id, match.book.id)
        try execute("INSERT INTO ZBKLIBRARYASSET VALUES ('edition-b','Renamed Reading','Author','\(safePath)')")
        XCTAssertThrowsError(try catalog.lookup(readerTitle: "Renamed Reading"))
        try execute("DELETE FROM ZBKLIBRARYASSET WHERE ZASSETID='edition-b'")
        try execute("UPDATE ZBKLIBRARYASSET SET ZPATH='https://example.com/fixture.epub'")
        XCTAssertNil(try catalog.lookup(readerTitle: "Renamed Reading"))
        try execute("UPDATE ZBKLIBRARYASSET SET ZPATH='\(safePath)',ZASSETID=''")
        XCTAssertNil(try catalog.lookup(readerTitle: "Renamed Reading"))
        try execute("UPDATE ZBKLIBRARYASSET SET ZASSETID='edition-a'")
        try FileManager.default.removeItem(at: epub)
        XCTAssertNil(try catalog.lookup(readerTitle: "Renamed Reading"))
    }
}

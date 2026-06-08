import XCTest
@testable import BooksCore

final class ReaderPaginationTests: XCTestCase {
    private func position(_ page: Int, total: Int? = nil, layout: String = "large",
                          panes: Int = 1) -> ReaderPagePosition {
        ReaderPagePosition(page: page, visiblePages: panes, layoutSignature: layout, totalPages: total)
    }

    func testHiddenTotalPersistsOnlyInTheCurrentLayout() {
        var pagination = ReaderPagination()
        XCTAssertEqual(pagination.observe(bookID: "book", sessionID: "s", position: position(72, total: 600), uptime: 1)?.totalPages, 600)
        XCTAssertEqual(pagination.observe(bookID: "book", sessionID: "s", position: position(73, panes: 2), uptime: 2)?.totalPages, 600)
        XCTAssertEqual(pagination.observe(bookID: "book", sessionID: "s", position: position(74, panes: 1), uptime: 2.5)?.totalPages, 600)
        let resized = pagination.observe(bookID: "book", sessionID: "s", position: position(100, total: 1000, layout: "small"), uptime: 3)
        XCTAssertEqual(resized?.page, 100)
        XCTAssertEqual(resized?.totalPages, 1000)
        XCTAssertEqual(pagination.observe(bookID: "book", sessionID: "s", position: position(101, layout: "small"), uptime: 4)?.totalPages, 1000)
        XCTAssertNil(pagination.observe(bookID: "book", sessionID: "s", position: position(74), uptime: 5)?.totalPages)
    }

    func testMissingTotalNeverFallsBackAcrossBoundaries() {
        for boundary in ["book", "session", "layout", "gap", "clock", "reset", "outOfRange"] {
            var pagination = ReaderPagination()
            _ = pagination.observe(bookID: "book", sessionID: "s", position: position(72, total: 600), uptime: 10)
            if boundary == "reset" { pagination.reset() }
            let result = pagination.observe(bookID: boundary == "book" ? "other" : "book",
                                            sessionID: boundary == "session" ? "other" : "s",
                                            position: position(boundary == "outOfRange" ? 601 : 73,
                                                               layout: boundary == "layout" ? "small" : "large"),
                                            uptime: boundary == "gap" ? 16 : boundary == "clock" ? 9 : 11)
            XCTAssertNil(result?.totalPages, boundary)
        }
    }

    func testChangedKnownTotalReplacesTheOldPairAndInvalidSamplesClearIt() {
        var pagination = ReaderPagination()
        _ = pagination.observe(bookID: "book", sessionID: "s", position: position(72, total: 600), uptime: 1)
        _ = pagination.observe(bookID: "book", sessionID: "s", position: position(72), uptime: 2)
        XCTAssertEqual(pagination.observe(bookID: "book", sessionID: "s", position: position(100, total: 1000), uptime: 3)?.totalPages, 1000)
        XCTAssertNil(pagination.observe(bookID: "book", sessionID: "s", position: position(100, total: 90), uptime: 4))
        XCTAssertNil(pagination.observe(bookID: "book", sessionID: "s", position: position(101), uptime: 5)?.totalPages)
    }
}

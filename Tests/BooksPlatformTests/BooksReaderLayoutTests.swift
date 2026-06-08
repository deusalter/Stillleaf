import XCTest
import BooksCore
@testable import BooksPlatform

final class BooksReaderLayoutTests: XCTestCase {
    private let window = CGSize(width: 1280, height: 769)

    func testChapterSplitsAndPixelJitterDoNotLoseFooterPages() throws {
        let shapes: [[CGFloat]] = [[1134], [531, 531], [530, 530], [1135], [1134], [1135], [1134]]
        let pages = [340, 341, 341, 342, 343, 344, 345]
        var tracker = PageTurnTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var signatures = Set<String>()
        var counted = 0
        for (index, widths) in shapes.enumerated() {
            let position = try XCTUnwrap(BooksReaderLayout.position(page: pages[index], totalPages: nil,
                windowSize: window, readerSize: window,
                paneSizes: widths.map { CGSize(width: $0, height: 613) }))
            signatures.insert(position.layoutSignature)
            XCTAssertEqual(position.visiblePages, 1, "Chapter count must not inflate navigation capacity")
            counted += tracker.observe(bookID: "fixture", sessionID: "reading", position: position,
                date: start.addingTimeInterval(Double(index)), uptime: 100 + Double(index))?.pagesRead ?? 0
        }
        XCTAssertEqual(signatures.count, 1)
        XCTAssertEqual(counted, 5)
    }

    func testHostAndWindowResizesChangeIdentityButFooterTotalDoesNot() throws {
        func position(windowSize: CGSize, host: CGSize, total: Int? = nil) throws -> ReaderPagePosition {
            try XCTUnwrap(BooksReaderLayout.position(page: 100, totalPages: total,
                windowSize: windowSize, readerSize: host, paneSizes: [CGSize(width: 1134, height: 613)]))
        }
        let initial = try position(windowSize: window, host: window)
        let resized = CGSize(width: 1281, height: 769)
        XCTAssertNotEqual(initial.layoutSignature, try position(windowSize: resized, host: window).layoutSignature)
        XCTAssertNotEqual(initial.layoutSignature, try position(windowSize: window, host: resized).layoutSignature)
        // Pagination handles total changes independently of geometry.
        XCTAssertEqual(initial.layoutSignature, try position(windowSize: window, host: window, total: 600).layoutSignature)
    }

    func testInvalidAndIncompleteGeometryCannotSupplyAPosition() {
        let pane = CGSize(width: 1134, height: 613)
        for invalid in [CGSize.zero, CGSize(width: -1, height: 20), CGSize(width: CGFloat.infinity, height: 20),
                        CGSize(width: CGFloat.nan, height: 20), CGSize(width: 100_000, height: 20)] {
            XCTAssertNil(BooksReaderLayout.position(page: 1, totalPages: nil, windowSize: invalid, readerSize: window, paneSizes: [pane]))
            XCTAssertNil(BooksReaderLayout.position(page: 1, totalPages: nil, windowSize: window, readerSize: invalid, paneSizes: [pane]))
            XCTAssertNil(BooksReaderLayout.position(page: 1, totalPages: nil, windowSize: window, readerSize: window, paneSizes: [invalid]))
        }
        for panes in [[], [pane, pane, pane]] {
            XCTAssertNil(BooksReaderLayout.position(page: 1, totalPages: nil, windowSize: window, readerSize: window, paneSizes: panes))
        }
    }
}

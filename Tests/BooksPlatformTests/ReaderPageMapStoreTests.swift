import Foundation
import XCTest
import BooksCore
@testable import BooksPlatform

final class ReaderPageMapStoreTests: XCTestCase {
    private let spine = ["one.xhtml", "two.xhtml", "three.xhtml"]
    private func publication(_ id: String = String(repeating: "c", count: 64)) -> EPUBPublication {
        EPUBPublication(id: id, title: "Fixture", authors: [], packagePath: "package.opf", resources: spine.map { EPUBResource(id: $0, path: $0, mediaType: "application/xhtml+xml") }, spine: spine, coverPath: nil, warnings: [])
    }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testFinishedMapsReturnNewestFirstOncePerLayoutAndBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillleaf-page-maps-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderPageMapStore(directory: root), book = publication()
        XCTAssertTrue(store.load(publication: book).isEmpty)
        XCTAssertTrue(store.record(try json(["key": "single", "counts": [3, 14, 1]]), publication: book))
        XCTAssertTrue(store.record(try json(["key": "facing", "counts": [2, 7, 1]]), publication: book))
        XCTAssertTrue(store.record(try json(["key": "single", "counts": [3, 15, 1]]), publication: book))
        let maps = store.load(publication: book)
        XCTAssertEqual(maps.compactMap { $0["key"] as? String }, ["single", "facing"])
        XCTAssertEqual(maps.first?["counts"] as? [Int], [3, 15, 1], "A corrected layout replaces its entry")
        for index in 0..<20 { store.record(try json(["key": "layout-\(index)", "counts": [1, 1, 1]]), publication: book) }
        XCTAssertEqual(store.load(publication: book).count, ReaderPageMapStore.maximumMaps)
        XCTAssertTrue(store.load(publication: publication(String(repeating: "d", count: 64))).isEmpty, "Maps belong to one edition")
        store.remove(publication: book)
        XCTAssertTrue(store.load(publication: book).isEmpty, "Removing a book forgets its maps")
    }

    func testMalformedMapsAndDamagedFilesOnlyMeanCountingAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillleaf-page-maps-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderPageMapStore(directory: root), book = publication()
        for value: [String: Any] in [["key": "k", "counts": [1, 2]], ["key": "k", "counts": [1, 0, 2]], ["key": "k", "counts": [1, 2.5, 2]],
                                     ["key": "k", "counts": [1, true, 2]], ["key": "", "counts": [1, 2, 3]], ["key": "k", "counts": [1, 2, 3], "position": 4]] {
            XCTAssertFalse(store.record(try json(value), publication: book), "\(value)")
        }
        XCTAssertFalse(store.record(Data("not json".utf8), publication: book))
        XCTAssertFalse(store.record(try json(["key": "k", "counts": [1, 2, 3]]), publication: publication("../escape")))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: root.appendingPathComponent(book.id + ".json"))
        XCTAssertTrue(store.load(publication: book).isEmpty)
        XCTAssertTrue(store.record(try json(["key": "k", "counts": [1, 2, 3]]), publication: book), "A damaged cache is replaced")
    }
}

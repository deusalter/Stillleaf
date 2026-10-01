import Foundation
import XCTest
import BooksCore
@testable import BooksPlatform

final class ReaderStateStoreTests: XCTestCase {
    func testLongSelectionUsesCompleteDOMEndpointsAndBoundedPreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillleaf-long-selection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = String(repeating: "a", count: 64)
        let publication = EPUBPublication(id: id, title: "Fixture", authors: [], packagePath: "package.opf", resources: [EPUBResource(id: "chapter", path: "chapter.xhtml", mediaType: "application/xhtml+xml")], spine: ["chapter.xhtml"], coverPath: nil, warnings: [])
        let store = ReaderStateStore(directory: root)
        let start: [String: Any] = ["cssSelector": "#passage", "textNodeIndex": 0, "charOffset": 0]
        let end: [String: Any] = ["cssSelector": "#passage", "textNodeIndex": 0, "charOffset": 17_000]
        let locator: [String: Any] = ["href": "chapter.xhtml", "locations": ["domRange": ["start": start, "end": end], "domRangeIndexing": "text-nodes"] as [String: Any]]
        let annotation: [String: Any] = ["id": "long", "locator": locator, "quote": String(repeating: "x", count: ReaderStateValidation.maximumLocatorText), "note": "Autosaved note", "color": "gold", "createdAt": "2026-09-24T12:00:00Z", "updatedAt": "2026-09-24T12:00:00Z"]
        var state: [String: Any] = ["schemaVersion": 1, "editionId": id, "revision": 1, "position": NSNull(), "preferences": ["theme": "system", "fontFamily": "publisher", "fontSize": 1.2, "lineHeight": 1.6, "measure": 65], "bookmarks": [], "annotations": [annotation]]
        let data = try JSONSerialization.data(withJSONObject: state)
        XCTAssertNoThrow(try ReaderStateValidation.validate(data, publication: publication))
        try store.save(data, publication: publication)
        XCTAssertEqual(try store.load(publication: publication), data, "Full selection endpoints survive persistence")
        var invalidLocator = locator
        invalidLocator["text"] = ["highlight": String(repeating: "x", count: 17_000)]
        var invalidAnnotation = annotation; invalidAnnotation["locator"] = invalidLocator
        state["annotations"] = [invalidAnnotation]; state["revision"] = 2
        XCTAssertThrowsError(try store.save(JSONSerialization.data(withJSONObject: state), publication: publication))
        XCTAssertEqual(try store.load(publication: publication), data, "Invalid locator cannot corrupt the saved state")
        var edited = annotation; edited["note"] = "Subsequent autosave"
        state["annotations"] = [edited]
        let updated = try JSONSerialization.data(withJSONObject: state)
        try store.save(updated, publication: publication)
        XCTAssertEqual(try store.load(publication: publication), updated)
    }
}

import Foundation
import XCTest
@testable import BooksCore

final class ReaderResourceMapTests: XCTestCase {
    private let shell = ReaderResourceMap.Asset(data: Data("<html></html>".utf8), mimeType: "text/html")
    private let chapter = ReaderResourceMap.FileAsset(file: URL(fileURLWithPath: "/tmp/book/chapter one.xhtml"),
                                                      mimeType: "application/xhtml+xml", byteCount: 11)
    private let image = ReaderResourceMap.FileAsset(file: URL(fileURLWithPath: "/tmp/book/cover.png"), mimeType: "image/png", byteCount: 4)

    func testPublicationFilesUseOpaqueExactSessionURLs() throws {
        let map = try ReaderResourceMap(resources: ["index.html": shell], files: [chapter, image])
        let first = try XCTUnwrap(map.fileURL(at: 0))
        XCTAssertEqual(first.absoluteString, map.origin.absoluteString + "book/0")
        XCTAssertEqual(map.file(for: try XCTUnwrap(map.fileURL(at: 1))), image)
        XCTAssertNil(map.fileURL(at: 2))
        XCTAssertNil(map.resource(for: first), "book files are not shell resources")
        XCTAssertNil(map.file(for: try XCTUnwrap(map.url(for: "index.html"))))
        for alias in [first.absoluteString + "?x", first.absoluteString + "#f", map.origin.absoluteString + "book/00"] {
            XCTAssertNil(map.file(for: try XCTUnwrap(URL(string: alias))), alias)
        }
        let other = try ReaderResourceMap(resources: [:], files: [chapter])
        XCTAssertNil(other.file(for: first), "another reader session cannot reuse this URL")
    }

    func testPublicationFilesAreBoundedAndValidated() {
        XCTAssertThrowsError(try ReaderResourceMap(resources: ["book/0": shell], files: [chapter]))
        XCTAssertThrowsError(try ReaderResourceMap(resources: [:], files: [chapter, image], maximumFileBytes: 12))
        XCTAssertThrowsError(try ReaderResourceMap(resources: [:], files: [
            .init(file: chapter.file, mimeType: "image/png", byteCount: ReaderResourceMap.maximumFileAssetBytes + 1)]))
        XCTAssertThrowsError(try ReaderResourceMap(resources: [:], files: [
            .init(file: URL(string: "https://example.com/a.png")!, mimeType: "image/png", byteCount: 1)]))
        XCTAssertThrowsError(try ReaderResourceMap(resources: [:], files: [.init(file: chapter.file, mimeType: "bad type", byteCount: 1)]))
        XCTAssertFalse(ReaderResourceMap.isValidMIMEType("text/html\r\nx: y"))
        XCTAssertTrue(ReaderResourceMap.isValidMIMEType("application/xhtml+xml"))
    }
}

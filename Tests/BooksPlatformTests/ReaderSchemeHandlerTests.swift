import Foundation
import XCTest
import BooksCore
@testable import BooksPlatform

final class ReaderSchemeHandlerTests: XCTestCase {
    func testReadsOnlyUnchangedRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chapter.xhtml")
        try Data("chapter".utf8).write(to: file)
        XCTAssertEqual(try ReaderSchemeHandler.read(.init(file: file, mimeType: "text/html", byteCount: 7)), Data("chapter".utf8))
        XCTAssertThrowsError(try ReaderSchemeHandler.read(.init(file: file, mimeType: "text/html", byteCount: 8)), "size changed since opening")
        let link = root.appendingPathComponent("link.xhtml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ReaderSchemeHandler.read(.init(file: link, mimeType: "text/html", byteCount: 7)), "symbolic link")
        XCTAssertThrowsError(try ReaderSchemeHandler.read(.init(file: root, mimeType: "text/html", byteCount: 0)), "directory")
        XCTAssertThrowsError(try ReaderSchemeHandler.read(.init(file: root.appendingPathComponent("missing"), mimeType: "text/html", byteCount: 0)))
    }
}

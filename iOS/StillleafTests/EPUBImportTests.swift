import XCTest
import BooksCore
import BooksPlatform
@testable import Stillleaf

/// On iOS the importer always uses the portable Compression-based ZIP reader.
final class EPUBImportTests: XCTestCase {
    private var scratch: Scratch!
    private var library: URL!

    override func setUpWithError() throws {
        scratch = try Scratch()
        library = scratch.url("Publications")
    }

    func testImportsStoredAndDeflatedEntriesByteForByte() throws {
        let entries = SyntheticEPUB.book(chapters: 2, paragraphs: 200)
        let result = try EPUBPublicationImporter(directory: library).importPublication(from: scratch.epub(entries: entries))
        XCTAssertEqual(result.publication.title, "A Synthetic Garden")
        XCTAssertEqual(result.publication.spine.count, 2)
        XCTAssertEqual(result.publication.toc?.map(\.title), ["Chapter 1", "Chapter 2"])
        for entry in entries where entry.path != "mimetype" && entry.path != "META-INF/container.xml" {
            let file = result.directory.appendingPathComponent("resources").appendingPathComponent(entry.path)
            XCTAssertEqual(try Data(contentsOf: file), entry.data, entry.path)
        }
    }

    func testRejectsCorruptedLinkedAndProtectedArchivesWithoutLeavingFiles() throws {
        let importer = EPUBPublicationImporter(directory: library)
        var corrupt = try Data(contentsOf: scratch.epub("corrupt.epub", entries: SyntheticEPUB.book()))
        // Damage a byte inside the first deflated chapter; its CRC no longer matches.
        let marker = corrupt.range(of: Data("EPUB/chapter1.xhtml".utf8))!
        corrupt[marker.upperBound + 20] ^= 0x5A
        try corrupt.write(to: scratch.url("corrupt.epub"))
        XCTAssertThrowsError(try importer.importPublication(from: scratch.url("corrupt.epub")))

        var linked = SyntheticEPUB.book()
        linked.append(.init(path: "EPUB/escape", data: Data("../../secret".utf8), deflate: false, unixMode: 0o120777))
        XCTAssertThrowsError(try importer.importPublication(from: scratch.epub("linked.epub", entries: linked))) { error in
            XCTAssertEqual(error.localizedDescription, "ZIP links, encryption, or entry limit rejected.")
        }

        var protected = SyntheticEPUB.book()
        protected.append(.init(path: "META-INF/sinf.xml", data: Data("<sinf/>".utf8)))
        XCTAssertThrowsError(try importer.importPublication(from: scratch.epub("protected.epub", entries: protected))) { error in
            XCTAssertTrue(error.localizedDescription.contains("protected by Apple Books"))
        }

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        XCTAssertEqual(leftovers, [], "no staging or partial editions remain")
    }

    func testIdenticalFilesShareOneEditionAndJournalID() throws {
        let importer = EPUBPublicationImporter(directory: library)
        let url = try scratch.epub()
        let first = try importer.importPublication(from: url)
        let copy = scratch.url("copy.epub")
        try FileManager.default.copyItem(at: url, to: copy)
        let second = try importer.importPublication(from: copy)
        XCTAssertTrue(second.alreadyImported)
        XCTAssertEqual(first.publication.id, second.publication.id)
        XCTAssertEqual(first.publication.id.count, 64, "SHA-256 of the file: the same ID the Mac assigns")
    }
}

import XCTest
import Foundation
import CSQLite
import BooksCore
@testable import BooksPlatform

/// Apple Books keeps EPUBs the reader added as unpacked folders. Stillleaf imports a copy
/// of such a folder; store purchases (FairPlay rights files) are refused.
final class EPUBBundleImportTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stillleaf-bundle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func bundle(_ name: String, extra: [String: String] = [:]) throws -> URL {
        let folder = root.appendingPathComponent(name + ".epub", isDirectory: true)
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": #"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#,
            "OEBPS/book.opf": #"<package xmlns="http://www.idpf.org/2007/opf" version="3.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Folder book</dc:title><dc:creator>Folder author</dc:creator></metadata><manifest><item id="ch" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="ch"/></spine></package>"#,
            "OEBPS/chapter.xhtml": "<html><body><p>Hello</p></body></html>",
            "iTunesMetadata.plist": "<plist/>",
            ".DS_Store": "finder junk"
        ]
        files.merge(extra) { $1 }
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return folder
    }

    func testUnpackedFolderImportsAsOneStableEdition() throws {
        let importer = EPUBPublicationImporter(directory: root.appendingPathComponent("Publications"))
        let folder = try bundle("Folder book")
        let first = try importer.importPublication(from: folder)
        XCTAssertFalse(first.alreadyImported)
        XCTAssertEqual(first.publication.title, "Folder book")
        XCTAssertEqual(first.publication.spine, ["OEBPS/chapter.xhtml"])
        let packed = try Data(contentsOf: first.directory.appendingPathComponent("original.epub"))
        XCTAssertEqual(String(decoding: packed[30..<38], as: UTF8.self), "mimetype", "mimetype is the first entry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.appendingPathComponent("resources/.DS_Store").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.appendingPathComponent("bundle.zip").path))
        let again = try importer.importPublication(from: folder)
        XCTAssertTrue(again.alreadyImported, "the same folder packs to the same edition")
        XCTAssertEqual(again.publication.id, first.publication.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".DS_Store").path), "the source folder is untouched")
    }

    func testFairPlayRightsAreRefused() throws {
        let importer = EPUBPublicationImporter(directory: root.appendingPathComponent("Publications"))
        let folder = try bundle("Store book", extra: ["META-INF/sinf.xml": "<fairplay/>"])
        XCTAssertThrowsError(try importer.importPublication(from: folder)) { error in
            XCTAssertTrue(error.localizedDescription.contains("protected by Apple Books"), error.localizedDescription)
        }
        let publications = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Publications").path)
        XCTAssertTrue(publications.isEmpty, "nothing is kept from a refused book: \(publications)")
    }

    func testLinksInsideFoldersAreRefused() throws {
        let importer = EPUBPublicationImporter(directory: root.appendingPathComponent("Publications"))
        let folder = try bundle("Linked book")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("OEBPS/outside.xhtml").path, withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try importer.importPublication(from: folder))
    }

    func testCatalogFindsAnAssetByID() throws {
        let folder = root.appendingPathComponent("BKLibrary")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("BKLibrary-test.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ZBKLIBRARYASSET (ZASSETID TEXT,ZTITLE TEXT,ZAUTHOR TEXT,ZPATH TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO ZBKLIBRARYASSET VALUES ('a','Book','Author','/tmp/Books/a.epub'),('b','Book','Author','file:///tmp/Books/b%20c.epub'),('d','Twin','Author','/tmp/d1.epub'),('d','Twin','Author','/tmp/d2.epub'),('e','No file','Author','')", nil, nil, nil), SQLITE_OK)
        let catalog = BooksCatalog(documents: root)
        XCTAssertEqual(try catalog.assetURL(forAssetID: "a")?.path, "/tmp/Books/a.epub")
        XCTAssertEqual(try catalog.assetURL(forAssetID: "b")?.path, "/tmp/Books/b c.epub")
        XCTAssertNil(try catalog.assetURL(forAssetID: "d"), "an ambiguous asset is not guessed")
        XCTAssertNil(try catalog.assetURL(forAssetID: "e"))
        XCTAssertNil(try catalog.assetURL(forAssetID: "missing"))
    }
}

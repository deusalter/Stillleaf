import XCTest
@testable import BooksPlatform

/// The iOS importer's ZIP reader, checked on macOS against archives written by an independent encoder.
final class PortableZIPExtractorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("portable-zip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testExtractsStoredAndDeflatedEntriesWithMatchingChecksums() throws {
        let text = String(repeating: "Synthetic chapter text. ", count: 400)
        let archive = try zip(name: "plain", entries: [
            .init(path: "mimetype", data: Data("application/epub+zip".utf8), deflate: false),
            .init(path: "EPUB/", data: Data(), deflate: false),
            .init(path: "EPUB/chapter.xhtml", data: Data(text.utf8), deflate: true),
            .init(path: "EPUB/empty.css", data: Data(), deflate: true)
        ])
        let content = directory.appendingPathComponent("plain-out")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let names = try PortableZIPExtractor(limits: .init()).extract(archive, to: content)
        XCTAssertEqual(names, ["mimetype", "EPUB/chapter.xhtml", "EPUB/empty.css"])
        XCTAssertEqual(try String(contentsOf: content.appendingPathComponent("EPUB/chapter.xhtml"), encoding: .utf8), text)
        XCTAssertEqual(try Data(contentsOf: content.appendingPathComponent("EPUB/empty.css")), Data())
    }

    func testRejectsCorruptChecksumLinksAndOversizedEntries() throws {
        var corrupt = try Data(contentsOf: zip(name: "crc", entries: [.init(path: "a.txt", data: Data("abc".utf8), deflate: false)]))
        // Flip the stored payload byte; the recorded CRC no longer matches.
        let payload = 30 + "a.txt".utf8.count
        corrupt[payload] ^= 0xFF
        let corruptURL = directory.appendingPathComponent("crc-bad.zip")
        try corrupt.write(to: corruptURL)
        XCTAssertThrowsError(try PortableZIPExtractor(limits: .init()).extract(corruptURL, to: directory))

        let link = try zip(name: "link", entries: [.init(path: "link", data: Data("target".utf8), deflate: false, unixMode: 0o120777)])
        XCTAssertThrowsError(try PortableZIPExtractor(limits: .init()).extract(link, to: directory)) { error in
            XCTAssertEqual((error as? EPUBImportError)?.errorDescription, "ZIP links, encryption, or entry limit rejected.")
        }

        var small = EPUBPublicationImporter.Limits()
        small.resourceBytes = 4
        let big = try zip(name: "big", entries: [.init(path: "big.txt", data: Data(count: 64), deflate: true)])
        XCTAssertThrowsError(try PortableZIPExtractor(limits: small).extract(big, to: directory))
    }

    func testCRC32KnownAnswer() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    private struct ZipEntry {
        let path: String
        let data: Data
        let deflate: Bool
        var unixMode: Int? = nil
    }

    /// Python's zipfile is an encoder independent of the extractor under test.
    private func zip(name: String, entries: [ZipEntry]) throws -> URL {
        let output = directory.appendingPathComponent(name + ".zip")
        let manifest = directory.appendingPathComponent(name + ".json")
        let rows: [[String: Any]] = entries.map {
            ["path": $0.path, "data": $0.data.base64EncodedString(), "deflate": $0.deflate, "mode": $0.unixMode ?? NSNull()]
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: manifest)
        let script = """
        import base64, json, sys, zipfile
        rows = json.load(open(sys.argv[1]))
        with zipfile.ZipFile(sys.argv[2], 'w') as z:
            for row in rows:
                info = zipfile.ZipInfo(row['path'])
                info.compress_type = zipfile.ZIP_DEFLATED if row['deflate'] else zipfile.ZIP_STORED
                if row['mode'] is not None:
                    info.create_system = 3
                    info.external_attr = row['mode'] << 16
                z.writestr(info, base64.b64decode(row['data']))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script, manifest.path, output.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return output
    }
}

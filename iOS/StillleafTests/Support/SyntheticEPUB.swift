import Foundation
import Compression

/// Builds small, generated EPUB 3 files for tests. Never uses real books.
/// The ZIP writer is independent of the importer's reader: it stores `mimetype`
/// first and uncompressed, and deflates other entries with Apple's encoder.
enum SyntheticEPUB {
    struct Entry {
        var path: String
        var data: Data
        var deflate = true
        /// The POSIX mode recorded for a Unix host; `0o120777` makes a symbolic link entry.
        var unixMode: UInt32 = 0o100644
    }

    /// A reflowable book with `chapters` chapters of generated prose and a PNG cover.
    static func book(title: String = "A Synthetic Garden", author: String = "Test Author", chapters: Int = 3,
                     paragraphs: Int = 40) -> [Entry] {
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        manifest += "<item id=\"cover\" href=\"cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>"
        var spine = "", navItems = ""
        var entries: [Entry] = [
            Entry(path: "mimetype", data: Data("application/epub+zip".utf8), deflate: false),
            Entry(path: "META-INF/container.xml", data: Data("""
            <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """.utf8))
        ]
        for chapter in 1...chapters {
            manifest += "<item id=\"c\(chapter)\" href=\"chapter\(chapter).xhtml\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(chapter)\"/>"
            navItems += "<li><a href=\"chapter\(chapter).xhtml\">Chapter \(chapter)</a></li>"
            let prose = (1...paragraphs).map { index in
                "<p>Paragraph \(index) of chapter \(chapter). The quiet leaves turned over in the evening light while the reader followed one line after another without hurry.</p>"
            }.joined()
            entries.append(Entry(path: "EPUB/chapter\(chapter).xhtml", data: Data("""
            <?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>Chapter \(chapter)</title></head><body><h1>Chapter \(chapter)</h1>\(prose)</body></html>
            """.utf8)))
        }
        entries.append(Entry(path: "EPUB/nav.xhtml", data: Data("""
        <?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol>\(navItems)</ol></nav></body></html>
        """.utf8)))
        entries.append(Entry(path: "EPUB/cover.png", data: onePixelPNG, deflate: false))
        entries.append(Entry(path: "EPUB/package.opf", data: Data("""
        <?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(title)</dc:title><dc:creator>\(author)</dc:creator><dc:language>en</dc:language></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
        """.utf8)))
        return entries
    }

    /// Writes `entries` as a ZIP file and returns its URL.
    @discardableResult
    static func write(_ entries: [Entry], to url: URL) throws -> URL {
        var archive = Data(), directory = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            var method: UInt16 = 0, payload = entry.data
            if entry.deflate, !entry.data.isEmpty, let compressed = deflate(entry.data) { method = 8; payload = compressed }
            let offset = UInt32(archive.count)
            archive.append(le32(0x04034b50)); archive.append(le16(20)); archive.append(le16(0)); archive.append(le16(method))
            archive.append(le16(0)); archive.append(le16(0x21)); archive.append(le32(crc))
            archive.append(le32(UInt32(payload.count))); archive.append(le32(UInt32(entry.data.count)))
            archive.append(le16(UInt16(name.count))); archive.append(le16(0)); archive.append(name); archive.append(payload)
            directory.append(le32(0x02014b50)); directory.append(le16(0x0314)); directory.append(le16(20)); directory.append(le16(0))
            directory.append(le16(method)); directory.append(le16(0)); directory.append(le16(0x21)); directory.append(le32(crc))
            directory.append(le32(UInt32(payload.count))); directory.append(le32(UInt32(entry.data.count)))
            directory.append(le16(UInt16(name.count))); directory.append(le16(0)); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le32(entry.unixMode << 16)); directory.append(le32(offset)); directory.append(name)
        }
        let start = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32(0x06054b50)); archive.append(le16(0)); archive.append(le16(0))
        archive.append(le16(UInt16(entries.count))); archive.append(le16(UInt16(entries.count)))
        archive.append(le32(UInt32(directory.count))); archive.append(le32(start)); archive.append(le16(0))
        try archive.write(to: url, options: .atomic)
        return url
    }

    /// A valid 1×1 PNG, so cover thumbnails have something to decode.
    static let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func deflate(_ data: Data) -> Data? {
        var output = Data(count: data.count + 1024)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                                          source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written > 0 ? output.prefix(written) : nil
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

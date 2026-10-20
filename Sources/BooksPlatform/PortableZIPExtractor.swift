import Foundation
import Compression

/// Extracts an EPUB whose central directory `preflightZIP` has already validated, using only
/// Foundation and the public Compression framework. iOS has no public libarchive, so this is its
/// extractor; macOS can select it with `STILLLEAF_PORTABLE_ZIP=1` so import checks cover both.
/// It applies the same entry rules as the libarchive path: no encryption, links or special files,
/// safe and alias-free paths, bounded sizes, and an exact length and CRC-32 for every file.
struct PortableZIPExtractor {
    private struct Entry {
        let name: String
        let flags: Int
        let method: Int
        let crc: UInt32
        let compressed: Int
        let size: Int
        let localOffset: Int
        let host: Int
        let externalAttributes: UInt32
    }

    let limits: EPUBPublicationImporter.Limits

    func extract(_ archiveURL: URL, to content: URL) throws -> Set<String> {
        let data = try Data(contentsOf: archiveURL, options: .alwaysMapped)
        var names = Set<String>(), aliases = Set<String>(), components: [String: String] = [:]
        var total = 0, count = 0
        for entry in try Self.entries(data) {
            count += 1
            guard count <= limits.entries, entry.flags & 0x0041 == 0 else {
                throw EPUBImportError.invalid("ZIP links, encryption, or entry limit rejected.")
            }
            let type = Self.fileType(entry)
            guard type != 0o120000 else { throw EPUBImportError.invalid("ZIP links, encryption, or entry limit rejected.") }
            let directory = type == 0o040000
            var name = entry.name
            if directory && name.hasSuffix("/") { name.removeLast() }
            name = try EPUBPublicationImporter.safePath(name)
            var parent = ""
            for component in name.split(separator: "/") {
                parent = parent.isEmpty ? String(component) : parent + "/" + component
                let key = parent.precomposedStringWithCanonicalMapping.lowercased()
                if let existing = components[key], existing != parent { throw EPUBImportError.invalid("Case or Unicode alias in ZIP resource path.") }
                components[key] = parent
            }
            let alias = name.precomposedStringWithCanonicalMapping.lowercased()
            guard aliases.insert(alias).inserted, type == 0o100000 || directory else { throw EPUBImportError.invalid("Duplicate, aliased, or special ZIP entry.") }
            let target = content.appendingPathComponent(name)
            if directory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); continue }
            guard entry.size <= limits.resourceBytes, entry.size <= limits.expandedBytes - total else { throw EPUBImportError.invalid("ZIP expanded size limit exceeded.") }
            let bytes = try Self.payload(of: entry, in: data)
            guard bytes.count == entry.size else { throw EPUBImportError.invalid("Truncated ZIP resource.") }
            guard CRC32.checksum(bytes) == entry.crc else { throw EPUBImportError.invalid("Corrupt ZIP resource.") }
            total += bytes.count
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw EPUBImportError.invalid("Cannot stage resource.") }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            try output.write(contentsOf: bytes)
            names.insert(name)
        }
        return names
    }

    /// Central-directory records in archive order. Preflight has bounded every offset used here.
    private static func entries(_ data: Data) throws -> [Entry] {
        func fail() -> EPUBImportError { .invalid("Malformed, unsupported, or unsafe ZIP directory.") }
        let base = data.startIndex
        func u16(_ p: Int) -> Int { Int(data[base + p]) | Int(data[base + p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
        guard data.count >= 22 else { throw fail() }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if u32(offset) == 0x06054b50, offset + 22 + u16(offset + 20) == data.count { end = offset; break }
        }
        guard let end else { throw fail() }
        var cursor = u32(end + 16), result: [Entry] = []
        for _ in 0..<u16(end + 10) {
            guard cursor + 46 <= end, u32(cursor) == 0x02014b50 else { throw fail() }
            let n = u16(cursor + 28), extra = u16(cursor + 30), comment = u16(cursor + 32)
            guard cursor + 46 + n <= end,
                  let name = String(data: data.subdata(in: base + cursor + 46..<base + cursor + 46 + n), encoding: .utf8) else { throw fail() }
            result.append(Entry(name: name, flags: u16(cursor + 8), method: u16(cursor + 10), crc: UInt32(u32(cursor + 16)),
                                compressed: u32(cursor + 20), size: u32(cursor + 24), localOffset: u32(cursor + 42),
                                host: u16(cursor + 4) >> 8, externalAttributes: UInt32(u32(cursor + 38))))
            cursor += 46 + n + extra + comment
        }
        return result
    }

    /// The POSIX file type, read as libarchive does: Unix hosts carry a mode in the high
    /// attribute bits; otherwise a trailing slash or the DOS directory bit marks a directory.
    private static func fileType(_ entry: Entry) -> UInt32 {
        let unixType = entry.externalAttributes >> 16 & 0o170000
        if entry.host == 3, unixType != 0 { return unixType }
        if entry.name.hasSuffix("/") || entry.externalAttributes & 0x10 != 0 { return 0o040000 }
        return 0o100000
    }

    private static func payload(of entry: Entry, in data: Data) throws -> Data {
        let base = data.startIndex
        func u16(_ p: Int) -> Int { Int(data[base + p]) | Int(data[base + p + 1]) << 8 }
        let start = entry.localOffset + 30 + u16(entry.localOffset + 26) + u16(entry.localOffset + 28)
        guard start >= 0, entry.compressed >= 0, start + entry.compressed <= data.count else { throw EPUBImportError.invalid("Truncated or malformed ZIP archive.") }
        let source = data.subdata(in: base + start..<base + start + entry.compressed)
        switch entry.method {
        case 0:
            return source
        case 8:
            if entry.size == 0 { return Data() }
            // One spare byte proves the stream holds no more than the declared length.
            var output = Data(count: entry.size + 1)
            let written = output.withUnsafeMutableBytes { destination in
                source.withUnsafeBytes { input in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                                              input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw EPUBImportError.invalid("Corrupt ZIP resource.") }
            return output.prefix(written)
        default:
            throw EPUBImportError.invalid("Malformed, unsupported, or unsafe ZIP directory.")
        }
    }
}

/// CRC-32 (IEEE 802.3), the checksum every ZIP entry records.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

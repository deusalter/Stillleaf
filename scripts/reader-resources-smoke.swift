import Foundation
import BooksCore

let text = ReaderResourceMap.Asset(data: Data("Chapter one".utf8), mimeType: "application/xhtml+xml")
let map = try ReaderResourceMap(resources: ["EPUB/chapter one.xhtml": text])
let url = map.url(for: "EPUB/chapter one.xhtml")!
precondition(map.resource(for: url)?.data == text.data)
for value in [url.absoluteString + "?alias=1", url.absoluteString + "#fragment",
              "https://example.com/EPUB/chapter%20one.xhtml", "file:///etc/passwd",
              map.origin.absoluteString + "EPUB/../EPUB/chapter%20one.xhtml",
              map.origin.absoluteString + "EPUB/chapter%2520one.xhtml"] {
    precondition(map.resource(for: URL(string: value)!) == nil)
}
let other = try ReaderResourceMap(resources: ["EPUB/chapter one.xhtml": text])
precondition(other.resource(for: url) == nil)
for path in ["../chapter", "/chapter", "a//b", "a/./b", "a\\b", "a%2fb", "a:b", "a\nb"] {
    do { _ = try ReaderResourceMap(resources: [path: text]); fatalError("Accepted unsafe path") }
    catch ReaderResourceMap.ValidationError.invalidPath {}
}
do { _ = try ReaderResourceMap(resources: ["a": text], maximumBytes: 2); fatalError("Accepted oversized assets") }
catch ReaderResourceMap.ValidationError.limitExceeded {}
do {
    _ = try ReaderResourceMap(resources: ["a": .init(data: Data(), mimeType: "text/html\r\nx:bad")])
    fatalError("Accepted malformed MIME")
} catch ReaderResourceMap.ValidationError.invalidType {}
// Publication files: opaque per-session URLs, exact matching, and their own budget.
let chapterFile = ReaderResourceMap.FileAsset(file: URL(fileURLWithPath: "/tmp/book/chapter one.xhtml"), mimeType: "application/xhtml+xml", byteCount: 11)
let imageFile = ReaderResourceMap.FileAsset(file: URL(fileURLWithPath: "/tmp/book/cover.png"), mimeType: "image/png", byteCount: 4)
let served = try ReaderResourceMap(resources: ["index.html": text], files: [chapterFile, imageFile])
precondition(served.fileURL(at: 0)?.absoluteString == served.origin.absoluteString + "book/0")
precondition(served.file(for: served.fileURL(at: 1)!) == imageFile && served.fileURL(at: 2) == nil && served.fileURL(at: -1) == nil)
precondition(served.resource(for: served.fileURL(at: 0)!) == nil && served.file(for: served.url(for: "index.html")!) == nil)
for value in [served.fileURL(at: 0)!.absoluteString + "?x", served.origin.absoluteString + "book/00", served.origin.absoluteString + "book/2",
              served.fileURL(at: 0)!.absoluteString.replacingOccurrences(of: served.origin.host!, with: "s00000000-0000-0000-0000-000000000000")] {
    precondition(served.file(for: URL(string: value)!) == nil)
}
let otherSession = try ReaderResourceMap(resources: [:], files: [chapterFile])
precondition(otherSession.file(for: served.fileURL(at: 0)!) == nil)
do { _ = try ReaderResourceMap(resources: ["book/0": text], files: [chapterFile]); fatalError("Accepted a shell path shadowing a book file") }
catch ReaderResourceMap.ValidationError.invalidPath {}
do { _ = try ReaderResourceMap(resources: [:], files: [.init(file: URL(string: "https://example.com/a")!, mimeType: "image/png", byteCount: 1)]); fatalError("Accepted a remote file") }
catch ReaderResourceMap.ValidationError.invalidPath {}
do { _ = try ReaderResourceMap(resources: [:], files: [chapterFile, imageFile], maximumFileBytes: 12); fatalError("Accepted files over budget") }
catch ReaderResourceMap.ValidationError.limitExceeded {}
do { _ = try ReaderResourceMap(resources: [:], files: [.init(file: chapterFile.file, mimeType: "image/png", byteCount: ReaderResourceMap.maximumFileAssetBytes + 1)]); fatalError("Accepted an oversized file") }
catch ReaderResourceMap.ValidationError.limitExceeded {}
do { _ = try ReaderResourceMap(resources: [:], files: [.init(file: chapterFile.file, mimeType: "bad type", byteCount: 1)]); fatalError("Accepted malformed file MIME") }
catch ReaderResourceMap.ValidationError.invalidType {}
print("reader-resources-smoke: exact allowlist, session isolation, path/type/budget denial, lazy publication file allowlist passed")

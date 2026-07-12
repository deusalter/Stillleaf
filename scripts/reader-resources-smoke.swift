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
print("reader-resources-smoke: exact allowlist, session isolation, path/type/budget denial passed")

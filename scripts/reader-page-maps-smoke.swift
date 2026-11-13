import Foundation
import BooksCore
import BooksPlatform

// The reader's page-map cache: validated, bounded, newest first, and separate from reading state.
let fm = FileManager.default
let temp = fm.temporaryDirectory.appendingPathComponent("stillleaf-page-maps-smoke-" + UUID().uuidString)
try fm.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temp) }
let edition = String(repeating: "c", count: 64)
let spine = ["one.xhtml", "two.xhtml", "three.xhtml"]
let publication = EPUBPublication(id: edition, title: "Synthetic", authors: [], packagePath: "package.opf", resources: spine.map { EPUBResource(id: $0, path: $0, mediaType: "application/xhtml+xml") }, spine: spine, coverPath: nil, warnings: [])
var failures = [String]()
func expect(_ condition: Bool, _ name: String) { if !condition { failures.append(name); print("FAIL: " + name) } }
func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
func keys(_ maps: [[String: Any]]) -> [String] { maps.compactMap { $0["key"] as? String } }

let stateDirectory = temp.appendingPathComponent("ReaderState")
let store = ReaderPageMapStore(directory: stateDirectory.appendingPathComponent("PageMaps"))
expect(store.load(publication: publication).isEmpty, "a book without saved maps opens with none")
expect(store.record(json(["key": "single-1300x860", "counts": [3, 14, 1]]), publication: publication), "a finished map is kept")
store.remove(publication: publication)
expect(store.load(publication: publication).isEmpty, "removing a book forgets its maps")
expect(store.record(json(["key": "single-1300x860", "counts": [3, 14, 1]]), publication: publication), "a map can be kept again after removal")
let loaded = store.load(publication: publication)
expect(keys(loaded) == ["single-1300x860"] && loaded.first?["counts"] as? [Int] == [3, 14, 1], "a saved map comes back unchanged")

for (name, value) in [
    ("wrong chapter count", ["key": "k", "counts": [1, 2]] as [String: Any]),
    ("zero screens", ["key": "k", "counts": [1, 0, 2]]),
    ("fractional screens", ["key": "k", "counts": [1, 2.5, 2]]),
    ("boolean screens", ["key": "k", "counts": [1, true, 2]]),
    ("too many screens", ["key": "k", "counts": [1, 2_000_000, 2]]),
    ("empty layout key", ["key": "", "counts": [1, 2, 3]]),
    ("oversized layout key", ["key": String(repeating: "x", count: 9_000), "counts": [1, 2, 3]]),
    ("extra fields", ["key": "k", "counts": [1, 2, 3], "position": 4]),
] {
    expect(!store.record(json(value), publication: publication), "rejects " + name)
}
expect(!store.record(Data("not json".utf8), publication: publication), "rejects malformed JSON")
expect(keys(store.load(publication: publication)) == ["single-1300x860"], "rejected maps leave the saved ones intact")

// Newest first, one entry per layout, bounded.
expect(store.record(json(["key": "facing-1300x860", "counts": [2, 7, 1]]), publication: publication), "a second layout is kept")
expect(store.record(json(["key": "single-1300x860", "counts": [3, 15, 1]]), publication: publication), "a corrected layout replaces its entry")
let reordered = store.load(publication: publication)
expect(keys(reordered) == ["single-1300x860", "facing-1300x860"] && reordered.first?["counts"] as? [Int] == [3, 15, 1], "the latest map for a layout is first")
for index in 0..<20 { store.record(json(["key": "layout-\(index)", "counts": [1, 1, 1]]), publication: publication) }
let bounded = store.load(publication: publication)
expect(bounded.count == ReaderPageMapStore.maximumMaps && bounded.first?["key"] as? String == "layout-19", "only the most recent layouts are kept")

// A damaged cache is only a cache: the book opens and counts again.
let file = stateDirectory.appendingPathComponent("PageMaps").appendingPathComponent(edition + ".json")
try Data("{broken".utf8).write(to: file)
expect(store.load(publication: publication).isEmpty, "a damaged cache loads as empty")
expect(store.record(json(["key": "single-1300x860", "counts": [3, 14, 1]]), publication: publication), "a damaged cache is replaced")
try json([["key": "a", "counts": [1, 2, 3]], ["key": "b", "counts": [1, 2]], "junk"]).write(to: file)
expect(keys(store.load(publication: publication)) == ["a"], "invalid entries in a saved file are skipped")

// Another edition, or an unsafe identifier, never reads or writes this book's file.
let other = EPUBPublication(id: String(repeating: "d", count: 64), title: "Other", authors: [], packagePath: "package.opf", resources: publication.resources, spine: spine, coverPath: nil, warnings: [])
expect(store.load(publication: other).isEmpty, "maps belong to one edition")
let unsafe = EPUBPublication(id: "../escape", title: "Unsafe", authors: [], packagePath: "package.opf", resources: publication.resources, spine: spine, coverPath: nil, warnings: [])
expect(!store.record(json(["key": "k", "counts": [1, 2, 3]]), publication: unsafe), "an unsafe edition id is refused")

// Page maps are not reading state: the state store sees no saved state for this book.
expect(try ReaderStateStore(directory: stateDirectory).load(publication: publication) == nil, "page maps never create reading state")

if failures.isEmpty { print("reader page map smoke checks passed") } else { exit(1) }

import Foundation
import CryptoKit
import BooksCore
import BooksPlatform

let fm = FileManager.default
let temp = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/mac-import").appendingPathComponent("stillleaf-removal-smoke-" + UUID().uuidString)
try fm.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temp) }
let root = temp.appendingPathComponent("managed"), trash = temp.appendingPathComponent("fixture-trash")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
try fm.createDirectory(at: trash, withIntermediateDirectories: true)
let journal = temp.appendingPathComponent("journal.json")
try Data("history reviews annotations".utf8).write(to: journal)
// Synthetic managed receipts exercise removal independently of the archive parser.
func fixture(_ name: String) throws -> (String, URL, Data) {
    let bytes = Data(("synthetic original " + name).utf8)
    let id = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let directory = root.appendingPathComponent(id), resources = directory.appendingPathComponent("resources")
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    try bytes.write(to: directory.appendingPathComponent("original.epub"))
    try Data("<package/>".utf8).write(to: resources.appendingPathComponent("package.opf"))
    try Data("<html/>".utf8).write(to: resources.appendingPathComponent("chapter.xhtml"))
    let publication = EPUBPublication(id: id, title: name, authors: [], packagePath: "package.opf", resources: [EPUBResource(id: "chapter", path: "chapter.xhtml", mediaType: "application/xhtml+xml")], spine: ["chapter.xhtml"], coverPath: nil, warnings: [])
    try JSONEncoder().encode(publication).write(to: directory.appendingPathComponent("publication.json"))
    return (id, directory, bytes)
}
let remover = EPUBAssetRemoval(directory: root) { source in
    let target = trash.appendingPathComponent(source.lastPathComponent)
    try fm.moveItem(at: source, to: target)
    return target
}
let (id, directory, bytes) = try fixture("export")
let destination = temp.appendingPathComponent("kept.epub")
let result = try remover.remove(publicationID: id, keepingOriginalAt: destination)
let kept = try Data(contentsOf: destination)
precondition(kept == bytes && result.exportedOriginal == destination && !fm.fileExists(atPath: directory.path))
precondition(fm.fileExists(atPath: result.trashedDirectory.appendingPathComponent("original.epub").path))
let (trashID, trashDirectory, _) = try fixture("trash")
let trashResult = try remover.remove(publicationID: trashID)
precondition(trashResult.exportedOriginal == nil && !fm.fileExists(atPath: trashDirectory.path))
func rejected(_ name: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Unexpected successful removal: " + name) } catch { print("rejected \(name)") }
}
let (existingID, existingDirectory, _) = try fixture("existing export")
rejected("export overwrite") { _ = try remover.remove(publicationID: existingID, keepingOriginalAt: destination) }
precondition(fm.fileExists(atPath: existingDirectory.path))
rejected("export within managed root") { _ = try remover.remove(publicationID: existingID, keepingOriginalAt: root.appendingPathComponent("kept.epub")) }
rejected("traversal ID") { _ = try remover.remove(publicationID: "../outside") }
rejected("missing edition") { _ = try remover.remove(publicationID: String(repeating: "0", count: 64)) }
let (linkID, linkDirectory, _) = try fixture("linked")
let linked = linkDirectory.appendingPathComponent("resources/chapter.xhtml")
try fm.removeItem(at: linked); try fm.createSymbolicLink(at: linked, withDestinationURL: journal)
rejected("resource symlink") { _ = try remover.remove(publicationID: linkID) }
let (sharedID, sharedDirectory, _) = try fixture("shared")
let shared = sharedDirectory.appendingPathComponent("resources/chapter.xhtml")
try fm.removeItem(at: shared); try fm.linkItem(at: journal, to: shared)
rejected("shared hardlink") { _ = try remover.remove(publicationID: sharedID) }
let (extraID, extraDirectory, _) = try fixture("additional data")
try Data("notes".utf8).write(to: extraDirectory.appendingPathComponent("annotations.json"))
rejected("unexpected edition data") { _ = try remover.remove(publicationID: extraID) }
let (failID, failDirectory, _) = try fixture("failure")
let failure = EPUBAssetRemoval(directory: root) { _ in throw NSError(domain: "SyntheticTrash", code: 1) }
let saved = temp.appendingPathComponent("saved-before-failure.epub")
do {
    _ = try failure.remove(publicationID: failID, keepingOriginalAt: saved)
    fatalError("Expected trash failure")
} catch EPUBAssetRemovalError.trashFailed(_, let exported) {
    precondition(exported == saved && fm.fileExists(atPath: failDirectory.path) && fm.fileExists(atPath: saved.path))
}
let rootLink = temp.appendingPathComponent("root-link")
try fm.createSymbolicLink(at: rootLink, withDestinationURL: root)
let unsafe = EPUBAssetRemoval(directory: rootLink) { _ in fatalError("Unsafe trash invoked") }
rejected("symlink root") { _ = try unsafe.remove(publicationID: existingID) }
let afterJournal = try Data(contentsOf: journal), afterExport = try Data(contentsOf: destination)
precondition(afterJournal == Data("history reviews annotations".utf8) && afterExport == bytes)
print("epub-removal-smoke: export/trash, non-overwrite, missing/unsafe/shared assets, failure preservation, journal preservation passed")

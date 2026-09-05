import Foundation
import CryptoKit
import BooksCore
import BooksPlatform

let fm = FileManager.default
let temporary = fm.temporaryDirectory.appendingPathComponent("stillleaf-transfer-smoke-" + UUID().uuidString)
try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temporary) }
let id = String(repeating: "a", count: 64)
let publication = EPUBPublication(id: id, title: "Synthetic transfer", authors: [], packagePath: "package.opf", resources: [EPUBResource(id: "chapter", path: "chapter.xhtml", mediaType: "application/xhtml+xml")], spine: ["chapter.xhtml"], coverPath: nil, warnings: [])
let locator: [String: Any] = ["href": "chapter.xhtml", "locations": ["progression": 0.25], "privateHostPath": "/synthetic/private"]
func state(_ revision: Int, note: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "editionId": id, "revision": revision,
        "position": locator, "preferences": ["theme": "custom", "fontFamily": "literata", "fontSize": 1.2, "lineHeight": 1.6, "measure": 65, "scroll": true, "fontWeight": NSNull(), "textAlign": "start", "hyphens": NSNull(), "letterSpacing": 0.125, "wordSpacing": 0.75, "columns": "two", "contentWidth": 97.5, "sideMargin": 14.25, "immersive": true, "backgroundColor": "#aBcD12", "textColor": NSNull()] as [String: Any],
        "bookmarks": [["id": "bookmark", "locator": locator, "label": "Remember", "createdAt": "2026-09-24T12:00:00Z"] as [String: Any]],
        "annotations": [["id": "annotation", "locator": locator, "quote": "Synthetic quote", "note": note, "color": "gold", "createdAt": "2026-09-24T12:00:00Z", "updatedAt": "2026-09-24T12:00:00Z"] as [String: Any]], "privateToken": "synthetic-secret"] as [String: Any])
}
func rejects(_ name: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Accepted " + name) } catch { print("rejected " + name) }
}
let sourceStore = ReaderStateStore(directory: temporary.appendingPathComponent("source"))
let exporter = ReaderStateTransfer(store: sourceStore)
let file = temporary.appendingPathComponent("state.json")
rejects("empty-state export") { _ = try exporter.export(publication: publication, to: file) }
try sourceStore.save(state(2, note: "Portable personal note"), publication: publication)
let exported = try exporter.export(publication: publication, to: file)
let exportedData = try Data(contentsOf: file)
precondition(exported.sha256 == SHA256.hash(data: exportedData).map { String(format: "%02x", $0) }.joined())
precondition(!String(decoding: exportedData, as: UTF8.self).contains("synthetic-secret"))
precondition(!String(decoding: exportedData, as: UTF8.self).contains("/synthetic/private"))
rejects("export overwrite") { _ = try exporter.export(publication: publication, to: file) }
let destinationStore = ReaderStateStore(directory: temporary.appendingPathComponent("destination"))
let importer = ReaderStateTransfer(store: destinationStore)
let preview = try importer.previewImport(from: file, publication: publication)
precondition(preview.disposition == .newEditionState && preview.incomingAnnotations == 1 && preview.incomingBookmarks == 1)
let applied = try importer.apply(preview); precondition(applied)
let duplicate = try importer.previewImport(from: file, publication: publication)
precondition(duplicate.disposition == .identical)
let duplicateApplied = try importer.apply(duplicate); precondition(!duplicateApplied)
let restored = try destinationStore.load(publication: publication)!; precondition(restored == exportedData)
let restoredObject = try JSONSerialization.jsonObject(with: restored) as! [String: Any]
let restoredPrefs = restoredObject["preferences"] as! [String: Any]
precondition(restoredPrefs["scroll"] as? Bool == true && restoredPrefs["fontWeight"] is NSNull && restoredPrefs["hyphens"] is NSNull)
precondition(restoredPrefs["textAlign"] as? String == "start" && restoredPrefs["columns"] as? String == "two")
precondition(restoredPrefs["letterSpacing"] as? Double == 0.125 && restoredPrefs["wordSpacing"] as? Double == 0.75)
precondition(restoredPrefs["theme"] as? String == "custom" && restoredPrefs["fontFamily"] as? String == "literata")
precondition(restoredPrefs["contentWidth"] as? Double == 97.5 && restoredPrefs["sideMargin"] as? Double == 14.25 && restoredPrefs["immersive"] as? Bool == true)
precondition(restoredPrefs["backgroundColor"] as? String == "#aBcD12" && restoredPrefs["textColor"] is NSNull)
let newerFile = temporary.appendingPathComponent("newer.json")
try state(3, note: "Incoming changes").write(to: newerFile)
let newer = try importer.previewImport(from: newerFile, publication: publication)
precondition(newer.disposition == .replacement && newer.localRevision == 2)
rejects("unapproved replacement") { _ = try importer.apply(newer) }
try destinationStore.save(state(4, note: "Local changes after preview"), publication: publication)
rejects("changed local after preview") { _ = try importer.apply(newer, replacingExisting: true) }
let stale = try importer.previewImport(from: newerFile, publication: publication)
precondition(stale.disposition == .stale)
rejects("stale replacement even explicit") { _ = try importer.apply(stale, replacingExisting: true) }
try state(5, note: "Reviewed replacement").write(to: newerFile)
let accepted = try importer.previewImport(from: newerFile, publication: publication)
let replaced = try importer.apply(accepted, replacingExisting: true); precondition(replaced)
try state(5, note: "Different same-revision note").write(to: newerFile)
let equalConflict = try importer.previewImport(from: newerFile, publication: publication)
precondition(equalConflict.disposition == .replacement)
rejects("equal-revision differing state without approval") { _ = try importer.apply(equalConflict) }
let beforeInvalid = try destinationStore.load(publication: publication)!
let badFile = temporary.appendingPathComponent("bad.json")
var wrong = try JSONSerialization.jsonObject(with: beforeInvalid) as! [String: Any]
wrong["editionId"] = String(repeating: "b", count: 64)
try JSONSerialization.data(withJSONObject: wrong).write(to: badFile)
rejects("wrong edition") { _ = try importer.previewImport(from: badFile, publication: publication) }
wrong["editionId"] = id; wrong["schemaVersion"] = 99
try JSONSerialization.data(withJSONObject: wrong).write(to: badFile)
rejects("future schema") { _ = try importer.previewImport(from: badFile, publication: publication) }
try Data(repeating: 32, count: ReaderStateValidation.maximumBytes + 1).write(to: badFile)
rejects("oversized import") { _ = try importer.previewImport(from: badFile, publication: publication) }
let symbolicFile = temporary.appendingPathComponent("symbolic.json")
try fm.createSymbolicLink(at: symbolicFile, withDestinationURL: file)
rejects("symlink input") { _ = try importer.previewImport(from: symbolicFile, publication: publication) }
let afterInvalid = try destinationStore.load(publication: publication)!; precondition(afterInvalid == beforeInvalid)
// Verify the exported raw schema with the actual Windows host validator.
let node = Process(); node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
node.arguments = ["node", "-e", "const fs=require('node:fs'); const {validateState}=require(process.argv[1]); const value=JSON.parse(fs.readFileSync(process.argv[2],'utf8')); const validated=validateState(value,value.editionId,{manifest:[{path:'chapter.xhtml'}]}); require('node:assert/strict').deepEqual(validated.preferences,value.preferences); fs.writeFileSync(process.argv[3],JSON.stringify(validated)); console.log('Windows validator accepted native export');", URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Reader/desktop/src/reader-state.cjs").path, file.path, temporary.appendingPathComponent("node-export.json").path]
try node.run(); node.waitUntilExit(); precondition(node.terminationStatus == 0)
let nodeExport = temporary.appendingPathComponent("node-export.json")
let crossHostStore = ReaderStateStore(directory: temporary.appendingPathComponent("cross-host"))
let crossHostTransfer = ReaderStateTransfer(store: crossHostStore)
let crossHostPreview = try crossHostTransfer.previewImport(from: nodeExport, publication: publication)
let crossHostApplied = try crossHostTransfer.apply(crossHostPreview); precondition(crossHostApplied)
let crossHostState = try JSONSerialization.jsonObject(with: crossHostStore.load(publication: publication)!) as! [String: Any]
precondition(NSDictionary(dictionary: crossHostState["preferences"] as! [String: Any]).isEqual(to: restoredPrefs))
print("reader-state-transfer-smoke: checksummed portable JSON, no-overwrite export, private-field filtering, idempotence, explicit conflicts, stale/invalid protection, Windows parity passed")

import Foundation
import BooksCore
import BooksPlatform

let fm = FileManager.default
let temp = fm.temporaryDirectory.appendingPathComponent("stillleaf-state-smoke-" + UUID().uuidString)
try fm.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temp) }
let edition = String(repeating: "a", count: 64)
let publication = EPUBPublication(id: edition, title: "Synthetic", authors: [], packagePath: "package.opf", resources: [EPUBResource(id: "chapter", path: "chapter.xhtml", mediaType: "application/xhtml+xml")], spine: ["chapter.xhtml"], coverPath: nil, warnings: [])
let locator: [String: Any] = ["href": "chapter.xhtml", "type": "application/xhtml+xml", "locations": ["progression": 0.25, "fragments": ["epubcfi(/6/2)"]] as [String: Any], "text": ["highlight": "Synthetic passage"]]
let state: [String: Any] = ["schemaVersion": 1, "editionId": edition, "revision": 1, "position": locator, "preferences": ["theme": "paper", "fontFamily": "serif", "fontSize": 1.2, "lineHeight": 1.6, "measure": 65] as [String: Any], "bookmarks": [["id": "bookmark", "locator": locator, "label": "Passage", "createdAt": "2026-09-24T12:00:00Z"] as [String: Any]], "annotations": [["id": "note", "locator": locator, "quote": "Synthetic passage", "note": "Keep this note", "color": "yellow", "createdAt": "2026-09-24T12:00:00Z", "updatedAt": "2026-09-24T12:00:00Z"] as [String: Any]]]
func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
var failures = [String]()
func expect(_ condition: Bool, _ name: String) { if !condition { failures.append(name); print("FAIL: " + name) } }
func reject(_ name: String, mutation: (inout [String: Any]) -> Void) throws {
    var value = state; mutation(&value)
    do { try ReaderStateValidation.validate(data(value), publication: publication); failures.append(name); print("FAIL accepted: " + name) } catch {}
}
try ReaderStateValidation.validate(data(state), publication: publication)
try reject("schema version") { $0["schemaVersion"] = 2 }
try reject("boolean schema") { $0["schemaVersion"] = true }
try reject("boolean revision") { $0["revision"] = true }
try reject("wrong edition") { $0["editionId"] = String(repeating: "b", count: 64) }
try reject("unsafe href") { $0["position"] = ["href": "../outside.xhtml"] }
try reject("bogus locator progression") { $0["position"] = ["href": "chapter.xhtml", "locations": ["progression": 2.0]] as [String: Any] }
try reject("bogus locator context") { $0["position"] = ["href": "chapter.xhtml", "text": ["highlight": 123]] as [String: Any] }
try reject("missing preferences") { $0["preferences"] = [String: Any]() }
try reject("wrong preference types") { $0["preferences"] = ["theme": 1, "fontFamily": false] as [String: Any] }
try reject("invalid line height") { var p = $0["preferences"] as! [String: Any]; p["lineHeight"] = 100; $0["preferences"] = p }
try reject("invalid annotation timestamp") { var a = $0["annotations"] as! [[String: Any]]; a[0]["createdAt"] = "not-a-date"; $0["annotations"] = a }
var rangeState = state
let point: [String: Any] = ["cssSelector": "p:nth-child(2)", "textNodeIndex": 0, "charOffset": 4]
rangeState["position"] = ["href": "chapter.xhtml", "locations": ["domRange": ["start": point, "end": point]]] as [String: Any]
try ReaderStateValidation.validate(data(rangeState), publication: publication)
for invalidPoint in [["cssSelector": "p", "textNodeIndex": true], ["cssSelector": "p", "charOffset": -1], ["cssSelector": "p", "charOffset": 10_000_001], ["cssSelector": "p", "arbitrary": "payload"]] as [[String: Any]] {
    try reject("invalid saved DOM range") { $0["position"] = ["href": "chapter.xhtml", "locations": ["domRange": ["start": invalidPoint, "end": point]]] as [String: Any] }
}
let extendedPreferences: [String: Any] = ["scroll": true, "fontWeight": 550.5, "textAlign": "justify", "hyphens": false, "letterSpacing": 0.1, "wordSpacing": 1.0, "columns": "two"]
var extended = state
var extendedPrefs = state["preferences"] as! [String: Any]
extendedPreferences.forEach { extendedPrefs[$0.key] = $0.value }
extended["preferences"] = extendedPrefs
try ReaderStateValidation.validate(data(extended), publication: publication)
extendedPrefs["fontWeight"] = NSNull(); extendedPrefs["hyphens"] = NSNull(); extended["preferences"] = extendedPrefs
try ReaderStateValidation.validate(data(extended), publication: publication)
for (key, value) in [("scroll", 1), ("scroll", NSNull()), ("fontWeight", true), ("fontWeight", 99), ("fontWeight", 1001), ("textAlign", "center"), ("hyphens", 0), ("letterSpacing", true), ("wordSpacing", 1.1), ("columns", "three")] as [(String, Any)] {
    try reject("invalid optional preference " + key) { var p = $0["preferences"] as! [String: Any]; p[key] = value; $0["preferences"] = p }
}
var enlarged = state; var prefs = state["preferences"] as! [String: Any]; prefs["fontSize"] = 2.5; enlarged["preferences"] = prefs
do { try ReaderStateValidation.validate(data(enlarged), publication: publication) } catch { failures.append("valid shared font size 2.5 rejected") }
let directory = temp.appendingPathComponent("reader-state"), store = ReaderStateStore(directory: directory)
let initial = try data(state)
expect(try store.load(publication: publication) == nil, "empty store")
try store.save(initial, publication: publication)
expect(try store.load(publication: publication) == initial, "bookmark and note bytes retained")
var second = state; second["revision"] = 2
let latest = try data(second); try store.save(latest, publication: publication)
let primary = directory.appendingPathComponent(edition + ".json"), backup = primary.appendingPathExtension("bak")
expect(try Data(contentsOf: backup) == initial, "last good backup")
try Data("corrupt".utf8).write(to: primary)
expect(try store.load(publication: publication) == initial, "backup recovery")
expect(try Data(contentsOf: primary) == Data("corrupt".utf8), "corrupt file preserved")
try store.save(latest, publication: publication)
let recoveryFiles = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".recovery-") }
expect(recoveryFiles.count == 1, "corruption evidence retained after save")
if let recovery = recoveryFiles.first { expect(try Data(contentsOf: recovery) == Data("corrupt".utf8), "corrupt recovery bytes retained") }
var bad = state; bad["editionId"] = "wrong"
do { try store.save(data(bad), publication: publication); failures.append("invalid save accepted") } catch {}
expect(try Data(contentsOf: primary) == latest, "invalid save preserves primary")
do { try store.save(initial, publication: publication) } catch {}
expect(try store.load(publication: publication) == latest, "stale revision cannot erase latest note")
let assets = temp.appendingPathComponent("publications").appendingPathComponent(edition)
try fm.createDirectory(at: assets, withIntermediateDirectories: true)
try Data("synthetic assets".utf8).write(to: assets.appendingPathComponent("original.epub"))
let savedBeforeRemoval = try store.load(publication: publication)
try fm.removeItem(at: assets)
expect(try store.load(publication: publication) == savedBeforeRemoval, "asset removal preserves independent state")
let outside = temp.appendingPathComponent("outside-state")
try fm.createDirectory(at: outside, withIntermediateDirectories: true)
let link = temp.appendingPathComponent("linked-state")
try fm.createSymbolicLink(at: link, withDestinationURL: outside)
do { try ReaderStateStore(directory: link).save(initial, publication: publication); failures.append("symlink root save accepted") } catch {}
expect(!fm.fileExists(atPath: outside.appendingPathComponent(edition + ".json").path), "symlink state root cannot write outside")
// If neither copy is valid, preserve both and report recovery failure instead of overwriting.
let brokenRoot = temp.appendingPathComponent("both-damaged")
try fm.createDirectory(at: brokenRoot, withIntermediateDirectories: true)
let brokenPrimary = brokenRoot.appendingPathComponent(edition + ".json")
try Data("bad-primary".utf8).write(to: brokenPrimary)
try Data("bad-backup".utf8).write(to: brokenPrimary.appendingPathExtension("bak"))
let brokenStore = ReaderStateStore(directory: brokenRoot)
do { _ = try brokenStore.load(publication: publication); failures.append("both damaged load accepted") } catch {}
do { try brokenStore.save(initial, publication: publication); failures.append("both damaged save overwrote evidence") } catch {}
expect(try Data(contentsOf: brokenPrimary) == Data("bad-primary".utf8), "both damaged primary preserved")
var nonlinear = publication
nonlinear.resources.append(EPUBResource(id: "appendix", path: "appendix.xhtml", mediaType: "application/xhtml+xml"))
var nonlinearState = state; nonlinearState["position"] = ["href": "appendix.xhtml"]
do { try ReaderStateValidation.validate(data(nonlinearState), publication: nonlinear) } catch { failures.append("nonlinear manifest resource rejected") }
if !failures.isEmpty { print("reader-state-smoke failures: \(failures.count)"); exit(1) }
print("reader-state-smoke: contract validation, note/bookmark retention, backup recovery, invalid/stale save preservation, removal isolation passed")

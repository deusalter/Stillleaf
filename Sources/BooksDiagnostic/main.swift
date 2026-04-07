import AppKit
import BooksPlatform
import Foundation

let includeMetadata = CommandLine.arguments.contains("--include-metadata")
if CommandLine.arguments.contains("--request-access") { BooksCapture.requestAccess() }
let appURL = URL(fileURLWithPath: "/System/Applications/Books.app")
let bundle = Bundle(url: appURL)
let catalog = BooksCatalog()
var report: [String: Any] = [
    "reportVersion": 1,
    "observedAt": ISO8601DateFormatter().string(from: Date()),
    "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
    "booksVersion": bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "not installed",
    "accessibilityTrusted": BooksCapture.isTrusted,
    "booksRunning": !NSRunningApplication.runningApplications(withBundleIdentifier: BooksCapture.bundleID).isEmpty,
    "booksForeground": SystemEligibility.booksForeground,
    "displayAwake": SystemEligibility.displayAwake,
    "sessionUnlocked": SystemEligibility.unlocked,
    "windows": BooksCapture.windowReport(includeMetadata: includeMetadata),
    "privacy": "No prose, screenshots, keystrokes, unrelated app titles, database writes or network calls. Metadata excluded unless requested.",
    "readerRule": "Focused AXDocument must exactly match a unique catalog asset path; otherwise automatic tracking pauses.",
    "livePage": "untested / not collected",
    "savedProgressFreshness": "unverified; never used as proof of current reading",
    "multiWindowBehavior": "focused window implementation; live verification requires Accessibility permission"
]
do {
    let columns = try catalog.columns()
    report["catalog"] = ["readable": true, "availableRequiredColumns": Array(columns.intersection(["ZASSETID", "ZTITLE", "ZAUTHOR", "ZPATH", "ZREADINGPROGRESS", "ZPAGECOUNT", "ZCOVERURL"])).sorted()] as [String: Any]
} catch { report["catalog"] = ["readable": false, "error": error.localizedDescription] as [String: Any] }
let resources = appURL.appendingPathComponent("Contents/Resources")
let scripting = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil))?.filter { ["sdef", "scriptSuite", "scriptTerminology"].contains($0.pathExtension) }.map(\.lastPathComponent) ?? []
report["scriptingDefinitionFiles"] = scripting
report["declaresAppleScript"] = bundle?.object(forInfoDictionaryKey: "NSAppleScriptEnabled") as? Bool ?? false
if includeMetadata {
    let result = BooksCapture().capture()
    report["capture"] = ["health": result.health, "bookID": result.book?.id ?? "unavailable", "title": result.book?.title ?? "unavailable", "author": result.book?.author ?? "unavailable"]
}
if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let output = String(data: data, encoding: .utf8) { print(output) }

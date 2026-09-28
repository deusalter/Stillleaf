import Foundation
@testable import BooksCore

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let date = Date(timeIntervalSince1970: 1_700_000_000)
let interval = ReadingInterval(sessionID: "session", bookID: "book", start: date,
    end: date.addingTimeInterval(100), duration: 100, timezoneID: "UTC", mode: .automatic)
func event(_ a: Int, _ b: Int, second: Double, content: ReaderContentCoverage? = nil, session: String = "session") -> AuditEvent {
    AuditEvent(date: date.addingTimeInterval(second), kind: "pageTurn", bookID: "book", sessionID: session,
        detail: "fixture", pageTurn: PageTurnEvidence(fromPage: a, toPage: b, pagesRead: b-a,
            visiblePages: 1, layoutSignature: "stable", content: content))
}
var coverage = ReadingCoverage()
var footer = PageTurnEvidence(fromPage: 10, toPage: 11, pagesRead: 1, visiblePages: 1, layoutSignature: "apple")
require(coverage.pages(footer, bookID: "book", sessionID: "s") == 1, "first footer observation")
footer.totalPages = 100
require(coverage.pages(footer, bookID: "book", sessionID: "s") == 0, "learning total does not reset coverage")
footer.totalPages = nil
require(coverage.pages(footer, bookID: "book", sessionID: "s") == 0, "hiding total does not reset coverage")
let repeated = [event(10, 11, second: 1), event(10, 11, second: 3), event(9, 12, second: 4)]
require(PageStatistics.pages(events: repeated, effectiveIntervals: [interval], merges: []) == 3, "backtracking and partial overlap")
require(PageStatistics.pages(events: repeated, effectiveIntervals: [interval], merges: [], from: date.addingTimeInterval(2), through: date.addingTimeInterval(4)) == 0, "date filtering cannot erase prior coverage")
let encoded = try JSONEncoder().encode(repeated)
let restored = try JSONDecoder().decode([AuditEvent].self, from: encoded)
require(PageStatistics.pages(events: restored, effectiveIntervals: [interval], merges: []) == 3, "reopening reconstructs coverage")
var later = interval; later.sessionID = "later"
require(PageStatistics.pages(events: repeated + [event(10, 11, second: 5, session: "later")], effectiveIntervals: [interval, later], merges: []) == 4, "new session permits rereading")
let splitIntervals = (0..<3).map { index in
    ReadingInterval(id: "split-\(index)", sessionID: "session", bookID: "book", start: date.addingTimeInterval(Double(index*10)), end: date.addingTimeInterval(Double(index*10+10)), duration: 10, timezoneID: "UTC", mode: .automatic, disposition: index == 1 ? .excluded : .credited)
}
let splitEvents = [event(10,11,second:5), event(10,11,second:25)]
let splitGroups = ReadingSessionGrouping.groups(intervals: splitIntervals, merges: [])
require(splitGroups.count == 2, "excluded interval splits display groups")
require(splitGroups.map { PageStatistics.pages(events: splitEvents, effectiveIntervals: splitIntervals, merges: [], within: $0.intervals) } == [1,0], "display split cannot recredit earlier surviving coverage")
require(PageStatistics.pagesPerMinute(events: splitEvents, effectiveIntervals: splitIntervals, merges: [], within: splitGroups[0].intervals) == 6, "selected pace uses selected elapsed time")
require(PageStatistics.pagesPerMinute(events: splitEvents, effectiveIntervals: splitIntervals, merges: [], within: splitGroups[1].intervals) == nil, "later group has no novel coverage for pace")
require(ReadingSessionGrouping.visibleGroups(splitGroups, events: splitEvents, merges: []).map(\.id) == [splitGroups[0].id], "split visibility must resolve session coverage first")
let native = [(0,100),(0,50),(50,150),(100,200)].enumerated().map { i, range in
    event(1+i, 2+i, second: Double(i+1), content: ReaderContentCoverage(resource: "one.xhtml", lower: range.0, upper: range.1))
}
require(PageStatistics.pages(events: native, effectiveIntervals: [interval], merges: []) == 2, "reflow deduplication and fractional carry")
let nativeReloaded = try JSONDecoder().decode([AuditEvent].self, from: JSONEncoder().encode(native))
require(PageStatistics.pages(events: nativeReloaded, effectiveIntervals: [interval], merges: []) == 2, "native coverage persists")
let position = try JSONDecoder().decode(NativeReaderPosition.self, from: Data(#"{"href":"one.xhtml","page":8,"totalPages":20,"visiblePages":1,"lower":120,"upper":320}"#.utf8))
let observation = position.observation(bookID: "book", spine: ["one.xhtml", "two.xhtml"])!
require(observation.reliable && observation.location == "Chapter 1 of 2 · Page 8 of 20", "actual native location")
require(observation.page == nil && observation.totalPages == nil && observation.fraction == nil, "chapter pages must not become book pages")
require(position.observation(bookID: "book", spine: ["other.xhtml"]) == nil, "reject foreign chapter")
let weighted = try JSONDecoder().decode(NativeReaderPosition.self, from: Data(#"{"href":"two.xhtml","page":3,"totalPages":9,"visiblePages":1,"bookOffset":900,"bookTotal":1200}"#.utf8))
require(weighted.observation(bookID: "book", spine: ["one.xhtml", "two.xhtml"])?.fraction == 0.75, "whole book content-weighted position")
var tracker = PageTurnTracker()
for (i,page) in [10,11,10,11,900,901].enumerated() {
    let evidence = tracker.observe(bookID: "book", sessionID: "session", position: ReaderPagePosition(page: page, visiblePages: 1, layoutSignature: "layout"), date: date.addingTimeInterval(Double(i)), uptime: 100+Double(i))
    if i == 4 { require(evidence == nil, "large jumps do not imply coverage") }
}
let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: temp) }
let store = try ReadingStore(url: temp.appendingPathComponent("history.sqlite"))
try store.saveBook(BookRecord(id: "book", title: "Fixture"))
for (i,e) in native.enumerated() {
    let fragment = ReadingInterval(sessionID: "session", bookID: "book", start: date.addingTimeInterval(Double(i)), end: e.date, duration: 1, timezoneID: "UTC", mode: .automatic)
    try store.appendCheckpoint(interval: fragment, event: AuditEvent(date: e.date, kind: "trackingCheckpoint", bookID: "book", sessionID: "session", detail: "fixture"))
    try store.appendEvent(e)
}
let archive = try store.archive()
let effective = try store.effectiveIntervals()
require(PageStatistics.pages(events: archive.events, effectiveIntervals: effective, merges: []) == 2, "SQLite native content payload roundtrip")
let timeStore = try ReadingStore(url: temp.appendingPathComponent("time.sqlite"))
let engine = try TrackingEngine(store: timeStore, timezoneID: "UTC", uncertaintyThreshold: 1)
let textBook = BookRecord(id: "native", title: "Native", source: "stillleaf-epub")
for second in 0...4 {
    try engine.process(TrackingInput(date: date.addingTimeInterval(Double(second)), uptime: 100 + Double(second), book: textBook,
        progress: ProgressObservation(bookID: textBook.id, fraction: Double(second) / 4, location: "Page \(second)", source: "stillleaf-epub-location", reliable: true)))
}
try engine.stop(date: date.addingTimeInterval(4), uptime: 104)
let time = try timeStore.effectiveIntervals()
require(time.filter { $0.disposition == .credited }.reduce(0) { $0 + $1.duration } == 1, "relocation does not renew native activity credit")
require(time.reduce(0) { $0 + $1.duration } == 4, "time remains elapsed duration independent of percentage")
// Prepared queries must preserve coverage before date/group clipping, even for
// aliases, tied timestamps, manual corrections, and excluded fragments.
var aliasEvent = event(12, 13, second: 5)
aliasEvent.bookID = "alias"
let adjustment = AuditEvent(date: date.addingTimeInterval(5), kind: "manualPageAdjustment",
    bookID: "book", sessionID: "session", detail: "fixture",
    pageAdjustment: ManualPageAdjustmentEvidence(pages: -1, recordedAt: date.addingTimeInterval(5), reason: "Correction"))
let snapshotEvents = repeated + native + splitEvents + [aliasEvent, adjustment, event(10, 11, second: 5, session: "later")]
let snapshotIntervals = splitIntervals + [later]
let snapshotMerges = [BookMerge(sourceID: "alias", targetID: "book")]
let prepared = PageStatistics.snapshot(events: snapshotEvents, effectiveIntervals: snapshotIntervals, merges: snapshotMerges)
for book: String? in [nil, "book", "alias", "missing"] {
    for session: String? in [nil, "session", "later", "missing"] {
        for bounds: (Double?, Double?) in [(nil,nil), (0,5), (5,26), (2,4), (5,5), (6,5)] {
            for selection: [ReadingInterval]? in [nil, [], [splitIntervals[0]], [splitIntervals[1]], [splitIntervals[2]], [later]] {
                let from = bounds.0.map { date.addingTimeInterval($0) }
                let through = bounds.1.map { date.addingTimeInterval($0) }
                let original = PageStatistics.pages(events: snapshotEvents, effectiveIntervals: snapshotIntervals,
                    merges: snapshotMerges, from: from, through: through, bookID: book, sessionID: session, within: selection)
                require(prepared.pages(from: from, through: through, bookID: book, sessionID: session, within: selection) == original,
                    "prepared evidence preserves book/session/date/group query semantics")
            }
        }
    }
}
require(prepared.pages(bookID: "alias") == prepared.pages(bookID: "book"), "prepared aliases resolve canonically")
require(PageStatistics.snapshot(events: [], effectiveIntervals: [], merges: []).pages() == 0, "empty prepared history")
print("Progress coverage smoke passed")

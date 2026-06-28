import Foundation
import BooksCore

let origin = Date(timeIntervalSince1970: 1_700_006_395) // Five seconds before UTC midnight.
func interval(_ id: String, start: Double = 0, duration: Double = 5,
              book: String = "book", mode: ReadingMode = .automatic,
              disposition: IntervalDisposition = .credited) -> ReadingInterval {
    ReadingInterval(id: id, sessionID: id, bookID: book,
        start: origin.addingTimeInterval(start), end: origin.addingTimeInterval(start + duration),
        duration: duration, timezoneID: "UTC", mode: mode, disposition: disposition)
}
func groups(_ intervals: [ReadingInterval]) -> [ReadingSessionGroup] {
    ReadingSessionGrouping.groups(intervals: intervals, merges: [])
}
func visible(_ intervals: [ReadingInterval], events: [AuditEvent] = [],
             active: String? = nil, corrected: Set<String> = []) -> [ReadingSessionGroup] {
    ReadingSessionGrouping.visibleGroups(groups(intervals), events: events, merges: [],
        activeSessionID: active, correctedIntervalIDs: corrected)
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let tiny = interval("tiny")
check(visible([tiny]).isEmpty, "Completed five-second zero-page group should disappear")
check(visible([tiny], active: "tiny").count == 1, "Active zero-page group must remain")
check(visible([tiny], corrected: ["tiny"]).count == 1, "Explicit corrections must remain")
check(visible([interval("manual", mode: .manual)]).count == 1, "Manual time-only entry must remain")
check(visible([interval("import", mode: .imported)]).count == 1, "Imported entry must remain")
check(visible([interval("long", duration: 120)]).count == 1, "Two-minute time-only reading must remain")
check(visible([interval("short", duration: 119)]).isEmpty, "Short empty automatic group should disappear")
check(visible([interval("review", duration: 120, disposition: .uncertain)]).count == 1, "Meaningful uncertain evidence must remain reviewable")
let turn = AuditEvent(date: tiny.end, kind: "pageTurn", bookID: "book", sessionID: "tiny", detail: "fixture",
    pageTurn: PageTurnEvidence(fromPage: 1, toPage: 2, pagesRead: 1, visiblePages: 1, layoutSignature: "fixture"))
check(visible([tiny], events: [turn]).count == 1, "Observed reading must remain")
let manual = AuditEvent(date: tiny.end, kind: "manualPageAdjustment", bookID: "book", sessionID: "tiny", detail: "fixture",
    pageAdjustment: ManualPageAdjustmentEvidence(pages: 2, recordedAt: tiny.end, reason: "Correction"))
check(visible([tiny], events: [manual]).count == 1, "Manual page correction must remain")
let continuation = interval("continued", start: 10, duration: 5)
let combined = visible([tiny, continuation], events: [turn])
check(combined.count == 1 && combined[0].intervals.count == 2, "Group before suppressing empty fragments")
check(combined[0].creditedSeconds == 10, "Never credit the gap")
check(visible([tiny, interval("later", start: 1000)]).isEmpty, "Wall-clock span must not qualify brief visits")
let other = interval("other", start: 6, book: "other")
check(visible([tiny, other, continuation], events: [turn]).map(\.id) == ["tiny"], "Book boundaries must survive filtering")
check(visible([tiny, interval("excluded", start: 6, disposition: .excluded), continuation], events: [turn]).map(\.id) == ["tiny"], "Excluded barriers must survive filtering")
let split = ReadingSessionGrouping.groups(intervals: [tiny, continuation], merges: [], breakBeforeIntervalIDs: ["continued"])
check(ReadingSessionGrouping.visibleGroups(split, events: [], merges: [], correctedIntervalIDs: ["tiny", "continued"]).count == 2, "Explicit user splits must survive")
let crossing = interval("midnight", duration: 120)
let crossingGroups = visible([crossing])
check(crossingGroups.count == 1, "Midnight must not suppress meaningful whole session")
for offset in [0.0, 10.0] {
    let key = ReadingStatistics.dayKey(origin.addingTimeInterval(offset), timezoneID: "UTC")
    let totals = ReadingStatistics.daily(intervals: crossingGroups[0].intervals, goals: [], timezoneID: "UTC",
        from: crossing.start, through: crossing.end)
    check(totals.contains { $0.day == key && $0.creditedSeconds > 0 }, "Session remains on both days")
}
check(groups([tiny])[0].creditedSeconds == 5, "Underlying recorded evidence stays intact")
check(visible([tiny], events: [AuditEvent(date: tiny.end, kind: "pageTurn", bookID: "other", sessionID: "tiny", detail: "wrong book", pageTurn: turn.pageTurn)]).isEmpty, "Unrelated page evidence cannot rescue noise")
let mergedIntervals = [tiny, interval("merged", start: 10, book: "target")]
let merges = [BookMerge(sourceID: "book", targetID: "target")]
let mergedGroups = ReadingSessionGrouping.groups(intervals: mergedIntervals, merges: merges)
check(ReadingSessionGrouping.visibleGroups(mergedGroups, events: [turn], merges: merges).count == 1, "Merged identities must retain qualified page evidence")
print("Session History smoke checks passed")

// Large replay: explicit splits can share one session identity. Include both
// qualified pages and invalid/cross-boundary evidence, plus irrelevant audit
// noise, so the indexed path must agree with the original qualification rules.
let replayCount = 12_000
var replayIntervals: [ReadingInterval] = []
var replayEvents: [AuditEvent] = []
for index in 0..<replayCount {
    var item = interval("replay-\(index)", start: Double(index * 10))
    item.sessionID = "shared-session"
    replayIntervals.append(item)
    replayEvents.append(AuditEvent(date: item.end, kind: "trackingCheckpoint", bookID: item.bookID,
                                  sessionID: item.sessionID, detail: "fixture"))
    if index % 3 == 0 {
        replayEvents.append(AuditEvent(date: item.end, kind: "manualPageAdjustment", bookID: item.bookID,
            sessionID: item.sessionID, detail: "fixture",
            pageAdjustment: ManualPageAdjustmentEvidence(pages: 2, recordedAt: item.end, reason: "Correction")))
    } else {
        // Start-boundary evidence belongs to neither this fragment nor its gap.
        replayEvents.append(AuditEvent(date: item.start, kind: "pageTurn", bookID: item.bookID,
                                      sessionID: item.sessionID, detail: "boundary", pageTurn: turn.pageTurn))
    }
}
let replayGroups = ReadingSessionGrouping.groups(intervals: replayIntervals, merges: [],
    breakBeforeIntervalIDs: Set(replayIntervals.map(\.id)))
let replayStarted = ProcessInfo.processInfo.systemUptime
let replayVisible = ReadingSessionGrouping.visibleGroups(replayGroups, events: replayEvents, merges: [])
let replayElapsed = ProcessInfo.processInfo.systemUptime - replayStarted
check(replayVisible.count == replayCount / 3, "Large replay must retain only qualified corrections")
check(replayVisible.map(\.id) == stride(from: 0, to: replayCount, by: 3).map { "replay-\($0)" }, "Replay identities must match expected evidence")
// Compare with the existing full-event qualifier on a bounded sample.
for group in replayGroups.prefix(60) {
    let expected = PageStatistics.pages(events: replayEvents, effectiveIntervals: group.intervals, merges: []) > 0
    check(replayVisible.contains { $0.id == group.id } == expected, "Indexed candidate selection changed qualification")
}
check(replayElapsed < 5, "12,000 short groups should qualify within five seconds")
print("Session History replay: \(replayCount) groups, \(replayEvents.count) events in \(replayElapsed) seconds")

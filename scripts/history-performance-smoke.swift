import Foundation
import BooksCore

func check(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}
func measure(_ name: String, _ body: () -> Void) {
    let start = Date()
    for _ in 0..<10 { body() }
    print("\(name): \(Date().timeIntervalSince(start) * 100) ms/run (10 runs)")
}
let start = ISO8601DateFormatter().date(from: "2024-01-01T00:00:00Z")!
let end = start.addingTimeInterval(366 * 86400)
var intervals: [ReadingInterval] = []
var events: [AuditEvent] = []
for i in 0..<3280 {
    let date = start.addingTimeInterval(Double(i * 9600))
    let duration = i % 17 == 0 ? 0.0 : Double(60 + i % 200000)
    let book = "book-\(i % 62)"
    let session = "session-\(i)"
    intervals.append(ReadingInterval(id: session, sessionID: session, bookID: book, start: date,
        end: date.addingTimeInterval(duration), duration: duration == 0 ? 120 : duration / 2,
        timezoneID: "UTC", mode: i % 3 == 0 ? .manual : .automatic,
        disposition: i % 13 == 0 ? .excluded : i % 7 == 0 ? .uncertain : .credited))
    events.append(AuditEvent(date: date.addingTimeInterval(duration), kind: "pageTurn", bookID: book,
        sessionID: session, detail: "Synthetic fixture", pageTurn: PageTurnEvidence(fromPage: i + 1,
        toPage: i + 3, pagesRead: 2, visiblePages: 1, layoutSignature: "fixture")))
}
for i in 0..<2531 {
    events.append(AuditEvent(date: start.addingTimeInterval(Double(i / 2)), kind: "bookRated",
        bookID: "book-\(i % 62)", detail: "Synthetic rating", rating: BookRatingEvidence(value: i % 7 == 0 ? nil : Double(i % 11) / 2)))
}
let goals = [GoalChange(effectiveDay: "2023-12-01", minutes: 20, pages: 10),
             GoalChange(effectiveDay: "2024-03-10", minutes: 30, pages: 15)]
let merges = [BookMerge(sourceID: "book-1", targetID: "book-0")]
let ratings = BookHistory.ratings(events: events)
for id in (0..<63).map({ "book-\($0)" }) {
    check(ratings[id] == BookHistory.rating(bookID: id, events: events), "Rating equivalence: \(id)")
}
let tie = [AuditEvent(date: start, kind: "bookRated", bookID: "zero", detail: "", rating: BookRatingEvidence(value: 4)),
           AuditEvent(date: start, kind: "bookRated", bookID: "zero", detail: "", rating: BookRatingEvidence(value: 0))]
check(BookHistory.ratings(events: tie)["zero"] == 0, "Zero rating and equal-date later-input winner")
let clear = tie + [AuditEvent(date: start, kind: "bookRated", bookID: "zero", detail: "", rating: BookRatingEvidence(value: nil))]
check(BookHistory.ratings(events: clear)["zero"] == nil, "Clear must hide older rating")
let snapshot = PageStatistics.snapshot(events: events, effectiveIntervals: intervals, merges: merges)
for zone in ["UTC", "America/Los_Angeles", "Asia/Kolkata", "Australia/Lord_Howe", "Pacific/Apia"] {
    let days = ReadingStatistics.daily(intervals: intervals, goals: goals, timezoneID: zone, from: start, through: end)
    #if LEGACY_COMPARISON
    let old = LegacyReadingStatistics.daily(intervals: intervals, goals: goals, timezoneID: zone, from: start, through: end)
    check(days.count == old.count && zip(days, old).allSatisfy { a, b in
        a.day == b.day && a.creditedSeconds == b.creditedSeconds && a.uncertainSeconds == b.uncertainSeconds && a.manualSeconds == b.manualSeconds && a.goalMinutes == b.goalMinutes
    }, "Legacy daily equivalence: \(zone)")
    check(snapshot.daily(goals: goals, timezoneID: zone, from: start, through: end) ==
        LegacyPageStatistics.daily(events: events, effectiveIntervals: intervals, goals: goals, merges: merges, timezoneID: zone, from: start, through: end), "Legacy page daily equivalence")
    #endif
    check(days.allSatisfy { $0.creditedSeconds >= 0 }, "Nonnegative totals")
    check(snapshot.daily(goals: goals, timezoneID: zone, from: start, through: end) ==
        PageStatistics.daily(events: events, effectiveIntervals: intervals, goals: goals, merges: merges,
                             timezoneID: zone, from: start, through: end), "Page snapshot daily equivalence")
}
// Exact midnight, zero-wall-time credit, and both DST day lengths.
for (iso, hours) in [("2024-03-10T08:00:00Z", 23.0), ("2024-11-03T07:00:00Z", 25.0)] {
    let midnight = ISO8601DateFormatter().date(from: iso)!
    let next = midnight.addingTimeInterval(hours * 3600)
    let span = ReadingInterval(sessionID: "dst", bookID: "dst", start: midnight, end: next,
        duration: hours * 3600, timezoneID: "America/Los_Angeles", mode: .automatic)
    let zero = ReadingInterval(sessionID: "zero", bookID: "dst", start: next, end: next,
        duration: 120, timezoneID: "America/Los_Angeles", mode: .manual)
    let bins = ReadingStatistics.daily(intervals: [span, zero], goals: [], timezoneID: "America/Los_Angeles", from: midnight, through: next)
    check(bins.count == 2 && bins[0].creditedSeconds == hours * 3600 && bins[1].manualSeconds == 120, "DST and midnight zero-duration attribution")
    let clipped = ReadingStatistics.daily(intervals: [span, zero], goals: [], timezoneID: "America/Los_Angeles", from: next, through: next)
    check(clipped.count == 1 && clipped[0].creditedSeconds == 120, "Clip interval ending at range start")
}
check(ReadingStatistics.daily(intervals: intervals, goals: [], timezoneID: "UTC", from: end, through: start).isEmpty, "Reversed time range")
check(snapshot.daily(goals: [], timezoneID: "UTC", from: end, through: start).isEmpty, "Reversed page range")
measure("daily time bins") { _ = ReadingStatistics.daily(intervals: intervals, goals: goals, timezoneID: "America/Los_Angeles", from: start, through: end) }
#if LEGACY_COMPARISON
measure("legacy daily time bins") { _ = LegacyReadingStatistics.daily(intervals: intervals, goals: goals, timezoneID: "America/Los_Angeles", from: start, through: end) }
#endif
measure("page daily rebuilding evidence") { _ = PageStatistics.daily(events: events, effectiveIntervals: intervals, goals: goals, merges: merges, timezoneID: "UTC", from: start, through: end) }
measure("page daily reusing evidence") { _ = snapshot.daily(goals: goals, timezoneID: "UTC", from: start, through: end) }
var checksum = 0.0
measure("62 rating scans") { for i in 0..<62 { checksum += BookHistory.rating(bookID: "book-\(i)", events: events) ?? 0 } }
measure("prepare ratings and 62 lookups") { let prepared = BookHistory.ratings(events: events); for i in 0..<62 { checksum += prepared["book-\(i)"] ?? 0 } }
print("history-performance-smoke passed; checksum \(checksum)")

import Foundation
import BooksCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
let start = date("2026-03-08T07:30:00Z"), end = date("2026-03-08T10:30:00Z")
let interval = ReadingInterval(sessionID: "s", bookID: "source", start: start, end: end, duration: 5400, timezoneID: "America/Los_Angeles", mode: .manual)
let period = DateInterval(start: date("2026-03-07T08:00:00Z"), end: date("2026-03-09T07:00:00Z"))
let merges = [BookMerge(sourceID: "source", targetID: "target")]
let days = HistoryAtlas.days(intervals: [interval], merges: merges, period: period, timezoneID: "America/Los_Angeles")
require(days.count == 2 && abs(days[0].creditedSeconds - 900) < 0.001 && abs(days[1].creditedSeconds - 4500) < 0.001, "DST clipping changed credited time")
require(days.allSatisfy { $0.books.first?.bookID == "target" }, "Merged lane identity changed")
let grouped = ReadingSessionGrouping.groups(intervals: [interval], merges: merges)
require(grouped.first?.bookID == days[0].books[0].bookID, "Lane selection disagrees with session identity")
var excluded = interval; excluded.disposition = .excluded
require(HistoryAtlas.days(intervals: [excluded], merges: [], period: period, timezoneID: "America/Los_Angeles").allSatisfy { $0.creditedSeconds == 0 }, "Excluded time colored a ring")
let midnight = date("2026-09-27T00:00:00Z"), audioStart = midnight.addingTimeInterval(-3600)
let audioInterval = ReadingInterval(sessionID: "corrected", bookID: "audio", start: audioStart, end: midnight.addingTimeInterval(3600), duration: 7200, timezoneID: "UTC", mode: .listening, audioSessionID: "original")
let group = ReadingSessionGroup(id: "audio-group", bookID: "linked-text", start: audioStart, end: audioInterval.end, intervals: [audioInterval], creditedSeconds: 7200)
let historical = AudiobookProgress(positionSeconds: 100, durationSeconds: 1000)
let observations = [ProgressObservation(bookID: "audio", observedAt: audioStart.addingTimeInterval(600), source: "audio", audio: historical, sessionID: "original"), ProgressObservation(bookID: "audio", observedAt: midnight, source: "audio", audio: AudiobookProgress(positionSeconds: 900, durationSeconds: 1000), sessionID: "original")]
require(HistoryAtlas.audioPosition(in: group, observations: observations, during: DateInterval(start: audioStart, end: midnight)) == historical, "Historical audio leaked a newer position")
let fallStart = date("2026-11-01T07:00:00Z"), fallEnd = date("2026-11-02T08:00:00Z")
let fall = ReadingInterval(sessionID: "fall", bookID: "b", start: fallStart, end: fallEnd, duration: 7200, timezoneID: "America/Los_Angeles", mode: .manual)
let fallDays = HistoryAtlas.days(intervals: [fall], merges: [], period: DateInterval(start: fallStart, end: fallEnd), timezoneID: "America/Los_Angeles")
require(fallDays.count == 1 && abs(fallDays[0].creditedSeconds - 7200) < 0.001, "Fall DST introduced an extra day")
print("history-atlas-smoke: DST, half-open clipping, corrected duration, exclusions, merged session/lane identity, historical audio passed")

import XCTest
@testable import BooksCore

final class HistoryAtlasTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testCrossMidnightUsesCorrectedDurationAcrossSpringDST() {
        let start = date("2026-03-08T07:30:00Z"), end = date("2026-03-08T10:30:00Z")
        let interval = ReadingInterval(sessionID: "s", bookID: "b", start: start, end: end, duration: 5400, timezoneID: "America/Los_Angeles", mode: .manual)
        let period = DateInterval(start: date("2026-03-07T08:00:00Z"), end: date("2026-03-09T07:00:00Z"))
        let days = HistoryAtlas.days(intervals: [interval], merges: [], period: period, timezoneID: "America/Los_Angeles")
        XCTAssertEqual(days.map(\.key), ["2026-03-07", "2026-03-08"])
        XCTAssertEqual(days[0].creditedSeconds, 900, accuracy: 0.001)
        XCTAssertEqual(days[1].creditedSeconds, 4500, accuracy: 0.001)
    }

    func testFallDSTAndHalfOpenEndDoNotCreateExtraDay() {
        let start = date("2026-11-01T07:00:00Z"), end = date("2026-11-02T08:00:00Z")
        let interval = ReadingInterval(sessionID: "s", bookID: "b", start: start, end: end, duration: 7200, timezoneID: "America/Los_Angeles", mode: .manual)
        let days = HistoryAtlas.days(intervals: [interval], merges: [], period: DateInterval(start: start, end: end), timezoneID: "America/Los_Angeles")
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].creditedSeconds, 7200, accuracy: 0.001)
        XCTAssertTrue(HistoryAtlas.slices(intervals: [interval], merges: [], period: DateInterval(start: end, duration: 86400)).isEmpty)
    }

    func testMergeIdentityMatchesSessionGroupingAndExclusionsDoNotColorRings() {
        let start = date("2026-09-26T08:00:00Z")
        let credit = ReadingInterval(sessionID: "source-session", bookID: "source", start: start, end: start.addingTimeInterval(600), duration: 600, timezoneID: "UTC", mode: .automatic)
        let pending = ReadingInterval(sessionID: "pending", bookID: "target", start: start.addingTimeInterval(1200), end: start.addingTimeInterval(1800), duration: 600, timezoneID: "UTC", mode: .manual, disposition: .uncertain)
        let excluded = ReadingInterval(sessionID: "excluded", bookID: "source", start: start.addingTimeInterval(3600), end: start.addingTimeInterval(4200), duration: 600, timezoneID: "UTC", mode: .manual, disposition: .excluded)
        let merges = [BookMerge(sourceID: "source", targetID: "target")]
        let intervals = [credit, pending, excluded], period = DateInterval(start: start, duration: 86400)
        let days = HistoryAtlas.days(intervals: intervals, merges: merges, period: period, timezoneID: "UTC")
        XCTAssertEqual(days[0].books.map(\.bookID), ["target"])
        XCTAssertEqual(days[0].creditedSeconds, 600)
        XCTAssertEqual(days[0].uncertainSeconds, 600)
        let groups = ReadingSessionGrouping.groups(intervals: intervals, merges: merges)
        XCTAssertTrue(groups.allSatisfy { $0.bookID == days[0].books[0].bookID })
        XCTAssertEqual(HistoryAtlas.slices(intervals: intervals, merges: merges, period: period).count, 3)
    }

    func testHistoricalAudioUsesSourceSessionAndExcludesNextMidnight() {
        let start = date("2026-09-26T23:00:00Z"), midnight = date("2026-09-27T00:00:00Z")
        let interval = ReadingInterval(sessionID: "corrected", bookID: "audio-edition", start: start, end: midnight.addingTimeInterval(3600), duration: 7200, timezoneID: "UTC", mode: .listening, audioSessionID: "original")
        let group = ReadingSessionGroup(id: "g", bookID: "linked-text", start: start, end: interval.end, intervals: [interval], creditedSeconds: 7200, uncertainSeconds: 0)
        let position = AudiobookProgress(positionSeconds: 1800, durationSeconds: 10000)
        let observations = [
            ProgressObservation(bookID: "audio-edition", observedAt: start.addingTimeInterval(1800), source: "audio", audio: position, sessionID: "original"),
            ProgressObservation(bookID: "audio-edition", observedAt: midnight, source: "audio", audio: AudiobookProgress(positionSeconds: 3600, durationSeconds: 10000), sessionID: "original"),
            ProgressObservation(bookID: "linked-text", observedAt: start.addingTimeInterval(2000), source: "audio", audio: AudiobookProgress(positionSeconds: 8000, durationSeconds: 10000), sessionID: "original")]
        XCTAssertEqual(HistoryAtlas.audioPosition(in: group, observations: observations, during: DateInterval(start: start, end: midnight)), position)
    }
}

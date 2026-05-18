import XCTest
@testable import BooksCore

final class ReadingSessionGroupingTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testAutomaticFragmentsAndShortInterruptionsGroupWithoutCreditingGaps() {
        let intervals = [
            interval("checkpoint-a", session: "same", start: 0, end: 1, duration: 1),
            interval("checkpoint-b", session: "same", start: 1, end: 5, duration: 4),
            interval("pause-a", session: "same", start: 6, end: 10, duration: 4, disposition: .uncertain),
            interval("pause-b", session: "new", start: 14, end: 21, duration: 7)
        ]
        let groups = ReadingSessionGrouping.groups(intervals: intervals.shuffled(), merges: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "checkpoint-a")
        XCTAssertEqual(groups[0].intervals.map(\.id), ["checkpoint-a", "checkpoint-b", "pause-a", "pause-b"])
        XCTAssertEqual(groups[0].start, origin)
        XCTAssertEqual(groups[0].end, origin.addingTimeInterval(21))
        XCTAssertEqual(groups[0].creditedSeconds, 12)
        XCTAssertEqual(groups[0].uncertainSeconds, 4)
        XCTAssertEqual(groups[0].creditedSeconds + groups[0].uncertainSeconds, 16)
    }

    func testExactMaximumBreakAndOtherActivitySeparateGroups() {
        let exactBreak = [
            interval("first", start: 0, end: 10, duration: 10),
            interval("second", start: 1_210, end: 1_220, duration: 10)
        ]
        XCTAssertEqual(ReadingSessionGrouping.groups(intervals: exactBreak, merges: []).count, 2)

        let interruptedByBook = [
            interval("a1", book: "a", start: 0, end: 10, duration: 10),
            interval("b", book: "b", start: 12, end: 20, duration: 8),
            interval("a2", book: "a", start: 22, end: 30, duration: 8)
        ]
        XCTAssertEqual(ReadingSessionGrouping.groups(intervals: interruptedByBook, merges: []).map(\.id),
                       ["a1", "b", "a2"])
    }

    func testExcludedActivityAndExplicitSplitAreBarriers() {
        let intervals = [
            interval("before", start: 0, end: 10, duration: 10),
            interval("excluded", start: 11, end: 12, duration: 1, disposition: .excluded),
            interval("after-excluded", start: 13, end: 20, duration: 7),
            interval("after-split", start: 20, end: 30, duration: 10)
        ]
        let groups = ReadingSessionGrouping.groups(intervals: intervals, merges: [],
            breakBeforeIntervalIDs: ["after-split"])
        XCTAssertEqual(groups.map(\.id), ["before", "after-excluded", "after-split"])
        XCTAssertFalse(groups.flatMap(\.intervals).contains { $0.id == "excluded" })
    }

    func testManualUsesSessionIdentityAndImportedIntervalsStaySeparate() {
        let intervals = [
            interval("manual-a", session: "manual", start: 0, end: 10, duration: 10, mode: .manual),
            interval("manual-b", session: "manual", start: 10_000, end: 10_010, duration: 10, mode: .manual),
            interval("manual-new", session: "other", start: 10_011, end: 10_020, duration: 9, mode: .manual),
            interval("import-a", session: "import", start: 10_021, end: 10_030, duration: 9, mode: .imported),
            interval("import-b", session: "import", start: 10_030, end: 10_040, duration: 10, mode: .imported)
        ]
        let groups = ReadingSessionGrouping.groups(intervals: intervals, merges: [])
        XCTAssertEqual(groups.map(\.intervals.count), [2, 1, 1, 1])
    }

    func testMergesAllowGroupingAndTimezoneDoesNotChangePresentationSession() {
        var first = interval("source", book: "source", start: 0, end: 10, duration: 10)
        first.timezoneID = "UTC"
        var second = interval("target", book: "target", start: 12, end: 20, duration: 8)
        second.timezoneID = "America/Los_Angeles"
        let groups = ReadingSessionGrouping.groups(intervals: [first, second],
            merges: [BookMerge(sourceID: "source", targetID: "target")])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].bookID, "target")
        XCTAssertEqual(groups[0].creditedSeconds, 18)
    }

    private func interval(_ id: String, session: String = "session", book: String = "book",
                          start: TimeInterval, end: TimeInterval, duration: TimeInterval,
                          mode: ReadingMode = .automatic,
                          disposition: IntervalDisposition = .credited) -> ReadingInterval {
        ReadingInterval(id: id, sessionID: session, bookID: book,
            start: origin.addingTimeInterval(start), end: origin.addingTimeInterval(end),
            duration: duration, timezoneID: "UTC", mode: mode, disposition: disposition)
    }
}

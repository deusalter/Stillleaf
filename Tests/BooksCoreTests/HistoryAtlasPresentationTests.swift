import XCTest
@testable import BooksCore

final class HistoryAtlasPresentationTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func source(_ intervals: [ReadingInterval] = [], events: [AuditEvent] = [],
                        progress: [ProgressObservation] = [], merges: [BookMerge] = [],
                        books: [BookRecord] = [BookRecord(id: "b", title: "Book")],
                        breaks: Set<String> = []) -> HistoryAtlasSource {
        HistoryAtlasSource(books: books, intervals: intervals, events: events, progress: progress, merges: merges,
            finishedBooks: BookHistory.completedBooks(books: books, events: events),
            pageEvidence: PageStatistics.snapshot(events: events, effectiveIntervals: intervals, merges: merges),
            breakBeforeIntervalIDs: breaks)
    }
    private func interval(_ id: String, start: Date, duration: Double = 600,
                          disposition: IntervalDisposition = .credited, bookID: String = "b") -> ReadingInterval {
        ReadingInterval(id: id, sessionID: "s", bookID: bookID, start: start, end: start.addingTimeInterval(duration),
            duration: duration, timezoneID: "UTC", mode: .automatic, disposition: disposition)
    }
    private func pageEvent(_ interval: ReadingInterval, from: Int, to: Int) -> AuditEvent {
        AuditEvent(date: interval.end, kind: "pageTurn", bookID: interval.bookID, sessionID: interval.sessionID,
            detail: "Synthetic", pageTurn: PageTurnEvidence(fromPage: from, toPage: to,
                pagesRead: to - from, visiblePages: 1, layoutSignature: "fixture"))
    }

    func testAllScalesMatchLegacyClippingAcrossDSTAndMerges() {
        let start = date("2026-03-08T07:30:00Z")
        var cross = interval("cross", start: start, duration: 10800, bookID: "source")
        cross.duration = 5400
        let pending = interval("pending", start: date("2026-03-09T08:00:00Z"), disposition: .uncertain)
        let excluded = interval("excluded", start: start.addingTimeInterval(600), disposition: .excluded)
        let input = source([cross, pending, excluded], merges: [BookMerge(sourceID: "source", targetID: "b")])
        for scale in CalendarScale.allCases {
            let navigation = CalendarNavigation(timezoneID: "America/Los_Angeles", anchor: start, scale: scale)
            let prepared = HistoryAtlasPeriod(source: input, navigation: navigation)
            XCTAssertEqual(prepared.days, HistoryAtlas.days(intervals: input.intervals, merges: input.merges,
                period: navigation.period, timezoneID: navigation.timezoneID))
            XCTAssertEqual(prepared.slices, HistoryAtlas.slices(intervals: input.intervals, merges: input.merges, period: navigation.period))
            XCTAssertEqual(prepared.creditedSeconds, prepared.days.reduce(0) { $0 + $1.creditedSeconds })
        }
    }

    func testQualifiedPagesKeepGlobalCoverageHalfOpenEndAndExcludedBarriers() {
        let first = interval("first", start: date("2026-09-25T12:00:00Z"))
        let repeatRead = interval("repeat", start: date("2026-09-26T12:00:00Z"))
        let novel = interval("novel", start: repeatRead.end.addingTimeInterval(20))
        let excluded = interval("excluded", start: novel.end.addingTimeInterval(20), disposition: .excluded)
        let midnight = interval("midnight", start: date("2026-09-26T23:50:00Z"))
        let events = [pageEvent(first, from: 1, to: 4), pageEvent(repeatRead, from: 1, to: 4),
            pageEvent(novel, from: 4, to: 6), pageEvent(excluded, from: 6, to: 9), pageEvent(midnight, from: 9, to: 11)]
        let input = source([first, repeatRead, novel, excluded, midnight], events: events)
        let navigation = CalendarNavigation(timezoneID: "UTC", anchor: repeatRead.start, scale: .day)
        let prepared = HistoryAtlasPeriod(source: input, navigation: navigation)
        XCTAssertEqual(prepared.pages, 2)
        XCTAssertEqual(prepared.pages, input.pageEvidence.pages(from: navigation.period.start, through: navigation.period.end))
        XCTAssertEqual(prepared.daysByKey["2026-09-26"]?.pagesByBook["b"], 2)
        XCTAssertEqual(prepared.sessions.reduce(0) { $0 + $1.pages }, 2)
        XCTAssertEqual(prepared.activeDays, 1)
        XCTAssertEqual(prepared.slices.filter { $0.interval.disposition == .excluded }.count, 1)
    }

    func testDaySessionsPreserveExplicitSplitsAndManualPages() {
        let first = interval("first", start: date("2026-09-26T12:00:00Z"))
        let second = interval("second", start: first.end)
        let adjustment = AuditEvent(date: first.end, kind: "manualPageAdjustment", bookID: "b", sessionID: "s",
            detail: "Synthetic", pageAdjustment: ManualPageAdjustmentEvidence(pages: 7, recordedAt: first.end, reason: "Synthetic"))
        let input = source([first, second], events: [adjustment], breaks: [second.id])
        let navigation = CalendarNavigation(timezoneID: "UTC", anchor: first.start, scale: .day)
        let prepared = HistoryAtlasPeriod(source: input, navigation: navigation)
        XCTAssertEqual(prepared.sessions.count, 2)
        XCTAssertEqual(prepared.sessions.map(\.manualPages), [7, 0])
        for session in prepared.sessions {
            XCTAssertEqual(session.manualPages, PageStatistics.manualPages(events: input.events,
                effectiveIntervals: session.session.intervals, merges: [], from: navigation.period.start,
                through: navigation.period.end, bookID: session.session.bookID))
        }
        XCTAssertEqual(prepared.displaySlicesByBook["b"]?.count, 1)
        XCTAssertEqual(prepared.displaySlicesByBook["b"]?.first?.seconds, 1200)
    }

    func testMonthHistoricalAudioUsesOriginalEditionAndSessionAfterCorrection() {
        let start = date("2026-09-26T23:00:00Z"), midnight = date("2026-09-27T00:00:00Z")
        let interval = ReadingInterval(id: "corrected", sessionID: "split", bookID: "audio", start: start,
            end: midnight.addingTimeInterval(3600), duration: 7200, timezoneID: "UTC", mode: .listening, audioSessionID: "original")
        let firstPosition = AudiobookProgress(positionSeconds: 1800, durationSeconds: 10000)
        let observations = [ProgressObservation(bookID: "audio", observedAt: start.addingTimeInterval(1800), source: "audio", audio: firstPosition, sessionID: "original"),
            ProgressObservation(bookID: "audio", observedAt: midnight, source: "audio", audio: AudiobookProgress(positionSeconds: 3600, durationSeconds: 10000), sessionID: "original"),
            ProgressObservation(bookID: "b", observedAt: start.addingTimeInterval(2000), source: "audio", audio: AudiobookProgress(positionSeconds: 9000, durationSeconds: 10000), sessionID: "original")]
        let input = source([interval], progress: observations, merges: [BookMerge(sourceID: "audio", targetID: "b")])
        let prepared = HistoryAtlasPeriod(source: input, navigation: CalendarNavigation(timezoneID: "UTC", anchor: start, scale: .month))
        XCTAssertEqual(prepared.daysByKey["2026-09-26"]?.positionsByBook["b"], firstPosition)
        XCTAssertEqual(prepared.daysByKey["2026-09-27"]?.positionsByBook["b"]?.positionSeconds, 3600)
    }

    func testYearRowsKeepDSTWidthsPendingMarksCompletionOnlyBooksAndTargets() {
        let start = date("2026-11-01T07:00:00Z")
        let credited = interval("credit", start: start, duration: 90000)
        let pending = interval("pending", start: start.addingTimeInterval(90000), disposition: .uncertain)
        let finish = date("2026-11-04T12:00:00Z")
        let events = [AuditEvent(date: finish, kind: "bookCompleted", bookID: "done", detail: "Synthetic",
            completion: BookCompletionEvidence(finishedAt: finish, source: "manual", imported: false))]
        let input = source([credited, pending], events: events,
            books: [BookRecord(id: "b", title: "Book"), BookRecord(id: "done", title: "Done")])
        let navigation = CalendarNavigation(timezoneID: "America/Los_Angeles", anchor: start, scale: .year)
        let prepared = HistoryAtlasPeriod(source: input, navigation: navigation, now: finish)
        XCTAssertEqual(prepared.yearRows.map(\.id), ["b", "done"])
        let row = prepared.yearRows[0]
        XCTAssertEqual(row.activity.count, 1)
        XCTAssertEqual((row.activity[0].end - row.activity[0].start) * navigation.period.duration, 90000, accuracy: 0.001)
        XCTAssertEqual(row.pending.count, 1)
        XCTAssertEqual(row.target, start) // Latest credited day retains precedence over later pending day.
        XCTAssertEqual(prepared.yearRows[1].finishes.count, 1)
        XCTAssertEqual(prepared.yearRows[1].target, navigation.calendar.startOfDay(for: finish))
        XCTAssertEqual(prepared.monthPositions.count, 12)
    }

    func testCacheBoundsAndInvalidationByRevisionTimezoneScalePeriodAndDay() async throws {
        let input = source(), now = date("2026-09-26T12:00:00Z")
        let cache = HistoryAtlasCache(capacity: 2)
        var navigation = CalendarNavigation(timezoneID: "UTC", anchor: now, scale: .day)
        let first = try await cache.presentation(source: input, navigation: navigation, now: now)
        let warm = try await cache.presentation(source: input, navigation: navigation, now: now)
        XCTAssertEqual(first.key, warm.key)
        navigation.move(by: -1)
        _ = try await cache.presentation(source: input, navigation: navigation, now: now)
        navigation.setScale(.month)
        _ = try await cache.presentation(source: input, navigation: navigation, now: now)
        let count = await cache.count
        XCTAssertEqual(count, 2)
        navigation.timezoneID = "America/Los_Angeles"
        let changedZone = try await cache.presentation(source: input, navigation: navigation, now: now)
        XCTAssertNotEqual(changedZone.key, warm.key)
        let newRevision = try await cache.presentation(source: source(), navigation: navigation, now: now)
        let newCount = await cache.count
        XCTAssertEqual(newCount, 1)
        XCTAssertNotEqual(newRevision.key.revision, first.key.revision)
        XCTAssertNotEqual(HistoryAtlasKey(source: input, navigation: navigation, now: now),
            HistoryAtlasKey(source: input, navigation: navigation, now: now.addingTimeInterval(86400)))
    }

    func testCancelledRequestNeverPopulatesCache() async throws {
        let input = source(), cache = HistoryAtlasCache()
        let navigation = CalendarNavigation(timezoneID: "UTC")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.presentation(source: input, navigation: navigation)
        }
        do { _ = try await task.value; XCTFail("Cancelled request was accepted") }
        catch is CancellationError { }
        let count = await cache.count
        XCTAssertEqual(count, 0)
    }

    func testRevisionReplacementCannotRetainDeletedPageTotals() async throws {
        let first = interval("first", start: date("2026-09-26T12:00:00Z"))
        let input = source([first], events: [pageEvent(first, from: 1, to: 6)])
        let navigation = CalendarNavigation(timezoneID: "UTC", anchor: first.start, scale: .month)
        let cache = HistoryAtlasCache()
        let before = try await cache.presentation(source: input, navigation: navigation)
        XCTAssertEqual(before.pages, 5)
        let after = try await cache.presentation(source: source(), navigation: navigation)
        XCTAssertEqual(after.pages, 0)
        XCTAssertEqual(after.creditedSeconds, 0)
        XCTAssertTrue(after.creditedBookIDs.isEmpty)
    }

    func testMonthIncludesPageOnlyDaysWithoutInventingRecordedTime() {
        var first = interval("first", start: date("2026-09-26T12:00:00Z"))
        first.duration = 0
        let input = source([first], events: [pageEvent(first, from: 1, to: 6)])
        let navigation = CalendarNavigation(timezoneID: "UTC", anchor: first.start, scale: .month)
        let prepared = HistoryAtlasPeriod(source: input, navigation: navigation)
        XCTAssertEqual(prepared.creditedSeconds, 0)
        XCTAssertEqual(prepared.activeDays, 1)
        XCTAssertEqual(prepared.daysByKey["2026-09-26"]?.bookIDs, ["b"])
        XCTAssertEqual(prepared.daysByKey["2026-09-26"]?.pagesByBook["b"], 5)
    }

    func testLatestRequestWinsIncludingReturnToEarlierSelection() {
        var gate = HistoryAtlasRequestGate()
        let day = gate.begin(), year = gate.begin(), returnedDay = gate.begin()
        XCTAssertFalse(gate.accepts(day))
        XCTAssertFalse(gate.accepts(year))
        XCTAssertTrue(gate.accepts(returnedDay))
    }
}

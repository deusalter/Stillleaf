import XCTest
@testable import BooksCore

final class PageTurnTests: XCTestCase {
    func testTrackerCountsOnlyShortConsecutiveForwardTransitions() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var tracker = PageTurnTracker()
        func position(_ page: Int, _ visible: Int = 1, _ layout: String = "one-up") -> ReaderPagePosition {
            ReaderPagePosition(page: page, visiblePages: visible, layoutSignature: layout)
        }

        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "session", position: position(10), date: start, uptime: 100))
        XCTAssertEqual(tracker.observe(bookID: "book", sessionID: "session", position: position(11), date: start.addingTimeInterval(1), uptime: 101)?.pagesRead, 1)
        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "session", position: position(11), date: start.addingTimeInterval(2), uptime: 102))
        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "session", position: position(14), date: start.addingTimeInterval(3), uptime: 103))
        XCTAssertEqual(tracker.observe(bookID: "book", sessionID: "session", position: position(15), date: start.addingTimeInterval(4), uptime: 104)?.pagesRead, 1)
        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "session", position: position(9), date: start.addingTimeInterval(5), uptime: 105))
        XCTAssertEqual(tracker.observe(bookID: "book", sessionID: "session", position: position(10), date: start.addingTimeInterval(6), uptime: 106)?.pagesRead, 1)

        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "session", position: position(20, 2, "two-up"), date: start.addingTimeInterval(7), uptime: 107))
        let spread = tracker.observe(bookID: "book", sessionID: "session", position: position(22, 2, "two-up"), date: start.addingTimeInterval(8), uptime: 108)
        XCTAssertEqual(spread, PageTurnEvidence(fromPage: 20, toPage: 22, pagesRead: 2, visiblePages: 2, layoutSignature: "two-up"))
        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "session", position: position(24, 1, "two-up"), date: start.addingTimeInterval(9), uptime: 109))
        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "other", position: position(25), date: start.addingTimeInterval(10), uptime: 110))
        XCTAssertNil(tracker.observe(bookID: "other", sessionID: "other", position: position(26), date: start.addingTimeInterval(11), uptime: 111))
    }

    func testTrackerMakesGapsInvalidSamplesAndClockChangesNewBaselines() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var tracker = PageTurnTracker(maximumGap: 50)
        let p: (Int) -> ReaderPagePosition = { ReaderPagePosition(page: $0, visiblePages: 1, layoutSignature: "layout") }
        XCTAssertEqual(tracker.maximumGap, 5)
        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "s", position: p(1), date: start, uptime: 1))
        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "s", position: p(2), date: start.addingTimeInterval(6), uptime: 7))
        XCTAssertEqual(tracker.observe(bookID: "book", sessionID: "s", position: p(3), date: start.addingTimeInterval(7), uptime: 8)?.pagesRead, 1)
        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "s", position: ReaderPagePosition(page: 0, visiblePages: 1, layoutSignature: "layout"), date: start.addingTimeInterval(8), uptime: 9))
        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "s", position: p(4), date: start.addingTimeInterval(9), uptime: 10))
        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "s", position: p(5), date: start.addingTimeInterval(-20), uptime: 11))
        XCTAssertEqual(tracker.observe(bookID: "book", sessionID: "s", position: p(6), date: start.addingTimeInterval(-19), uptime: 12)?.pagesRead, 1)
        tracker.reset()
        XCTAssertNil(tracker.observe(bookID: "book", sessionID: "s", position: p(7), date: start.addingTimeInterval(12), uptime: 13))
    }

    func testStorePersistsValidTypedEvidenceAndRejectsFabricatedCounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
        let book = BookRecord(id: "book", title: "Synthetic")
        try store.saveBook(book)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = ReadingInterval(id: "interval", sessionID: "session", bookID: book.id, start: start,
                                       end: start.addingTimeInterval(5), duration: 5, timezoneID: "UTC", mode: .automatic)
        try store.appendInterval(interval)
        let valid = AuditEvent(id: "turn", date: interval.end, kind: "pageTurn", bookID: book.id, sessionID: interval.sessionID,
                               detail: "Observed adjacent reader pages.",
                               pageTurn: PageTurnEvidence(fromPage: 10, toPage: 11, pagesRead: 1, visiblePages: 1, layoutSignature: "one-up"))
        try store.appendEvent(valid)
        XCTAssertEqual(try store.archive().events.first(where: { $0.id == valid.id })?.pageTurn, valid.pageTurn)

        let invalid = AuditEvent(id: "fabricated", date: interval.end, kind: "pageTurn", bookID: book.id, sessionID: interval.sessionID,
                                 detail: "invalid", pageTurn: PageTurnEvidence(fromPage: 1, toPage: 500, pagesRead: 499, visiblePages: 1, layoutSignature: "one-up"))
        XCTAssertThrowsError(try store.appendEvent(invalid))
        XCTAssertThrowsError(try store.appendEvent(AuditEvent(kind: "pageTurn", bookID: book.id, sessionID: "session", detail: "missing")))
        XCTAssertThrowsError(try store.appendEvent(AuditEvent(kind: "pageTurn", bookID: book.id, sessionID: "unknown", detail: "orphan",
            pageTurn: PageTurnEvidence(fromPage: 1, toPage: 2, pagesRead: 1, visiblePages: 1, layoutSignature: "one-up"))))
        let manual = ReadingInterval(id: "manual", sessionID: "manual", bookID: book.id,
                                     start: start.addingTimeInterval(10), end: start.addingTimeInterval(15),
                                     duration: 5, timezoneID: "UTC", mode: .manual)
        try store.appendInterval(manual)
        XCTAssertThrowsError(try store.appendEvent(turn(id: "manual-turn", date: manual.end, book: book.id,
                                                        session: manual.sessionID, from: 20, to: 21, visible: 1)))
        XCTAssertThrowsError(try store.appendEvent(turn(id: "mid-interval", date: start.addingTimeInterval(2),
                                                        book: book.id, session: interval.sessionID,
                                                        from: 11, to: 12, visible: 1)))
        XCTAssertThrowsError(try store.setGoal(GoalChange(effectiveDay: "2024-01-01", minutes: 20, pages: 0)))

        let export = directory.appendingPathComponent("history.json")
        try store.exportJSON(to: export)
        let imported = try ReadingStore(url: directory.appendingPathComponent("imported.sqlite"))
        try imported.importJSON(from: export)
        XCTAssertEqual(try imported.archive().events.first(where: { $0.id == valid.id })?.pageTurn, valid.pageTurn)

        let csv = directory.appendingPathComponent("csv")
        try store.exportCSV(to: csv)
        let eventsCSV = try String(contentsOf: csv.appendingPathComponent("events.csv"))
        XCTAssertTrue(eventsCSV.contains("from_page,to_page,pages_read,visible_pages,layout_signature"))
        XCTAssertTrue(eventsCSV.contains("10,11,1,1,one-up"))

        try store.deleteSession(interval.sessionID)
        XCTAssertFalse(try store.archive().events.contains { $0.id == valid.id })

        let second = ReadingInterval(id: "second", sessionID: "second", bookID: book.id, start: start.addingTimeInterval(20),
                                     end: start.addingTimeInterval(25), duration: 5, timezoneID: "UTC", mode: .automatic)
        try store.appendInterval(second)
        try store.appendEvent(turn(id: "second-turn", date: second.end, book: book.id, session: second.sessionID, from: 20, to: 21, visible: 1))
        try store.deleteBook(book.id)
        XCTAssertFalse(try store.archive().events.contains { $0.pageTurn != nil })
    }

    func testImportRejectsFabricatedLargePageEvidenceAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
        try store.saveBook(BookRecord(id: "kept", title: "Kept"))
        let before = try store.archive()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var archive = HistoryArchive()
        archive.books = [BookRecord(id: "bad", title: "Bad")]
        archive.intervals = [ReadingInterval(id: "interval", sessionID: "session", bookID: "bad", start: start,
                                             end: start.addingTimeInterval(5), duration: 5, timezoneID: "UTC", mode: .imported)]
        archive.events = [AuditEvent(id: "bad-turn", date: start.addingTimeInterval(5), kind: "pageTurn", bookID: "bad",
                                     sessionID: "session", detail: "fabricated",
                                     pageTurn: PageTurnEvidence(fromPage: 1, toPage: 1_000, pagesRead: 999,
                                                                visiblePages: 1, layoutSignature: "layout"))]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let url = directory.appendingPathComponent("bad.json")
        try encoder.encode(archive).write(to: url)
        XCTAssertThrowsError(try store.importJSON(from: url))
        var after = try store.archive()
        // Export time belongs to this read, not to the durable database state.
        after.exportedAt = before.exportedAt
        XCTAssertEqual(after, before)
    }

    func testStatisticsUseEffectiveIntervalsMergesAndHalfOpenDates() {
        let day = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 UTC
        let intervals = [
            ReadingInterval(id: "kept", sessionID: "kept", bookID: "source", start: day, end: day.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .automatic),
            ReadingInterval(id: "uncertain", sessionID: "uncertain", bookID: "target", start: day.addingTimeInterval(20), end: day.addingTimeInterval(30), duration: 10, timezoneID: "UTC", mode: .automatic, disposition: .uncertain),
            ReadingInterval(id: "excluded", sessionID: "excluded", bookID: "target", start: day.addingTimeInterval(40), end: day.addingTimeInterval(50), duration: 10, timezoneID: "UTC", mode: .automatic, disposition: .excluded)
        ]
        let events = [
            turn(id: "one", date: intervals[0].end, book: "source", session: "kept", from: 1, to: 2, visible: 1),
            turn(id: "two", date: intervals[1].end, book: "target", session: "uncertain", from: 10, to: 12, visible: 2),
            turn(id: "excluded", date: intervals[2].end, book: "target", session: "excluded", from: 20, to: 21, visible: 1),
            turn(id: "outside", date: day.addingTimeInterval(15), book: "target", session: "kept", from: 2, to: 3, visible: 1)
        ]
        let merges = [BookMerge(sourceID: "source", targetID: "target")]
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: intervals, merges: merges), 3)
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: intervals, merges: merges, bookID: "target"), 3)
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: intervals, merges: merges, sessionID: "kept"), 1)
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: intervals, merges: merges, from: day, through: intervals[1].end), 1)
    }

    func testBoundaryEventDoesNotSurviveThroughNextFragmentButInteriorCorrectionDoes() {
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let boundary = start.addingTimeInterval(10)
        let event = turn(id: "boundary", date: boundary, book: "book", session: "session",
                         from: 1, to: 2, visible: 1)
        let excludedSource = ReadingInterval(id: "excluded-source", sessionID: "session", bookID: "book",
            start: start, end: boundary, duration: 10, timezoneID: "UTC", mode: .automatic,
            disposition: .excluded)
        let next = ReadingInterval(id: "next", sessionID: "session", bookID: "book",
            start: boundary, end: start.addingTimeInterval(20), duration: 10, timezoneID: "UTC", mode: .automatic)
        XCTAssertEqual(PageStatistics.pages(events: [event], effectiveIntervals: [excludedSource, next], merges: []), 0)

        let corrected = ReadingInterval(id: "corrected", sessionID: "session", bookID: "book",
            start: start, end: start.addingTimeInterval(20), duration: 20, timezoneID: "UTC", mode: .automatic)
        XCTAssertEqual(PageStatistics.pages(events: [event], effectiveIntervals: [corrected], merges: []), 1)
    }

    func testDailyPageGoalsDoNotBackfillLegacyHistoryAndProducePageStreak() {
        let first = Date(timeIntervalSince1970: 1_704_067_200)
        let second = first.addingTimeInterval(86_400)
        let third = second.addingTimeInterval(86_400)
        let intervals = [
            ReadingInterval(id: "s1", sessionID: "s1", bookID: "book", start: first, end: first.addingTimeInterval(5), duration: 5, timezoneID: "UTC", mode: .automatic),
            ReadingInterval(id: "s2", sessionID: "s2", bookID: "book", start: second, end: second.addingTimeInterval(5), duration: 5, timezoneID: "UTC", mode: .automatic),
            ReadingInterval(id: "s3", sessionID: "s3", bookID: "book", start: third, end: third.addingTimeInterval(5), duration: 5, timezoneID: "UTC", mode: .automatic)
        ]
        let events = [
            turn(id: "e1", date: intervals[0].end, book: "book", session: "s1", from: 1, to: 2, visible: 1),
            turn(id: "e2", date: intervals[1].end, book: "book", session: "s2", from: 2, to: 4, visible: 2),
            turn(id: "e3", date: intervals[2].end, book: "book", session: "s3", from: 4, to: 6, visible: 2)
        ]
        let goals = [
            GoalChange(effectiveDay: "2024-01-01", minutes: 20),
            GoalChange(effectiveDay: "2024-01-02", minutes: 20, pages: 2)
        ]
        let daily = PageStatistics.daily(events: events, effectiveIntervals: intervals, goals: goals, merges: [], timezoneID: "UTC", from: first, through: third)
        XCTAssertEqual(daily.map(\.pages), [1, 2, 2])
        XCTAssertNil(daily[0].goalPages)
        XCTAssertFalse(daily[0].qualifies)
        XCTAssertTrue(daily[1].qualifies)
        XCTAssertTrue(daily[2].qualifies)
        let streak = PageStatistics.streak(days: daily, today: "2024-01-03")
        XCTAssertEqual(streak.current, 2)
        XCTAssertEqual(streak.longest, 2)
        XCTAssertFalse(streak.todayPending)
    }

    func testPagesPerMinuteUsesOnlyCreditedTimeAndEvidence() {
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let intervals = [
            ReadingInterval(id: "credited-source", sessionID: "credited", bookID: "source", start: start,
                            end: start.addingTimeInterval(120), duration: 120, timezoneID: "UTC", mode: .automatic),
            ReadingInterval(id: "uncertain-target", sessionID: "uncertain", bookID: "target",
                            start: start.addingTimeInterval(120), end: start.addingTimeInterval(180), duration: 60,
                            timezoneID: "UTC", mode: .automatic, disposition: .uncertain),
            ReadingInterval(id: "other", sessionID: "other", bookID: "other", start: start.addingTimeInterval(180),
                            end: start.addingTimeInterval(240), duration: 60, timezoneID: "UTC", mode: .automatic),
            ReadingInterval(id: "manual-target", sessionID: "manual", bookID: "target", start: start.addingTimeInterval(240),
                            end: start.addingTimeInterval(360), duration: 120, timezoneID: "UTC", mode: .manual)
        ]
        let events = [
            turn(id: "credited-one", date: start.addingTimeInterval(30), book: "source", session: "credited", from: 1, to: 2, visible: 1),
            turn(id: "credited-two", date: start.addingTimeInterval(60), book: "source", session: "credited", from: 2, to: 4, visible: 2),
            turn(id: "uncertain", date: start.addingTimeInterval(150), book: "target", session: "uncertain", from: 4, to: 6, visible: 2),
            turn(id: "manual", date: start.addingTimeInterval(300), book: "target", session: "manual", from: 6, to: 8, visible: 2)
        ]
        let merges = [BookMerge(sourceID: "source", targetID: "target")]
        XCTAssertEqual(PageStatistics.pagesPerMinute(events: events, effectiveIntervals: intervals, merges: merges,
                                                     bookID: "target"), 1.5)
        XCTAssertEqual(PageStatistics.pagesPerMinute(events: events, effectiveIntervals: intervals, merges: merges,
                                                     sessionID: "credited"), 1.5)
        XCTAssertNil(PageStatistics.pagesPerMinute(events: events, effectiveIntervals: intervals, merges: merges,
                                                   bookID: "other"))
        XCTAssertNil(PageStatistics.pagesPerMinute(events: [], effectiveIntervals: [], merges: [], bookID: "missing"))
    }

    func testLegacyOptionalFieldsDecodeAsNil() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let goal = try decoder.decode(GoalChange.self, from: Data(#"{"id":"g","effectiveDay":"2024-01-01","minutes":20,"createdAt":1704067200000}"#.utf8))
        XCTAssertNil(goal.pages)
        let event = try decoder.decode(AuditEvent.self, from: Data(#"{"id":"e","date":1704067200000,"kind":"legacy","detail":"old"}"#.utf8))
        XCTAssertNil(event.pageTurn)
        XCTAssertNil(event.completion)
        XCTAssertNil(event.rating)
    }

    private func turn(id: String, date: Date, book: String, session: String, from: Int, to: Int, visible: Int) -> AuditEvent {
        AuditEvent(id: id, date: date, kind: "pageTurn", bookID: book, sessionID: session,
                   detail: "Observed adjacent reader pages.",
                   pageTurn: PageTurnEvidence(fromPage: from, toPage: to, pagesRead: to - from,
                                              visiblePages: visible, layoutSignature: "layout-\(visible)"))
    }
}

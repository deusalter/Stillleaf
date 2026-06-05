import XCTest
@testable import BooksCore

final class ManualPageStatisticsTests: XCTestCase {
    func testManualCorrectionAddsToTotalsAndDailyPagesButNotAutomaticPace() {
        let calendar = calendar(in: "America/Los_Angeles")
        let september17 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 23, minute: 55))!
        let interval = ReadingInterval(id: "kept", sessionID: "kept", bookID: "source",
                                       start: september17.addingTimeInterval(600),
                                       end: september17.addingTimeInterval(660), duration: 60,
                                       timezoneID: "America/Los_Angeles", mode: .automatic)
        let observed = turn(id: "observed", date: interval.end, bookID: "source", sessionID: "kept", pages: 3)
        let correction = adjustment(id: "correction", date: interval.end, bookID: "source", sessionID: "kept",
                                    pages: 7, recordedAt: interval.end.addingTimeInterval(86_400))
        let merges = [BookMerge(sourceID: "source", targetID: "target")]

        XCTAssertEqual(PageStatistics.pages(events: [observed, correction], effectiveIntervals: [interval], merges: merges), 10)
        XCTAssertEqual(PageStatistics.manualPages(events: [observed, correction], effectiveIntervals: [interval], merges: merges, bookID: "target"), 7)
        XCTAssertEqual(PageStatistics.pages(events: [observed, correction], effectiveIntervals: [interval], merges: merges, sessionID: "kept"), 10)
        XCTAssertEqual(PageStatistics.pagesPerMinute(events: [observed, correction], effectiveIntervals: [interval], merges: merges, bookID: "target"), 3)

        let daily = PageStatistics.daily(events: [observed, correction], effectiveIntervals: [interval],
                                         goals: [GoalChange(effectiveDay: "2026-09-17", minutes: 20, pages: 10)], merges: merges,
                                         timezoneID: "America/Los_Angeles", from: september17, through: interval.end)
        XCTAssertEqual(daily.map(\.pages), [0, 10])
        XCTAssertEqual(daily.last?.day, "2026-09-18")
        XCTAssertEqual(PageStatistics.streak(days: daily, today: "2026-09-18").current, 1)
    }

    func testManualCorrectionRequiresItsSurvivingSourceIntervalAndHonorsFilters() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let kept = ReadingInterval(id: "kept", sessionID: "kept", bookID: "source", start: start,
                                   end: start.addingTimeInterval(60), duration: 60, timezoneID: "UTC", mode: .automatic)
        let excluded = ReadingInterval(id: "excluded", sessionID: "excluded", bookID: "source", start: kept.end,
                                       end: kept.end.addingTimeInterval(60), duration: 60, timezoneID: "UTC", mode: .automatic,
                                       disposition: .excluded)
        let retained = adjustment(id: "retained", date: kept.end, bookID: "source", sessionID: "kept", pages: 7, recordedAt: kept.end)
        let excludedEvent = adjustment(id: "excluded", date: excluded.end, bookID: "source", sessionID: "excluded", pages: 9, recordedAt: excluded.end)
        let invalid = AuditEvent(id: "invalid", date: kept.end, kind: "manualPageAdjustment", bookID: "source", sessionID: "kept",
                                 detail: "invalid", pageAdjustment: ManualPageAdjustmentEvidence(pages: 0, recordedAt: kept.end, reason: "Correction"))
        let merges = [BookMerge(sourceID: "source", targetID: "target")]
        let events = [retained, excludedEvent, invalid]

        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: [kept, excluded], merges: merges, bookID: "target"), 7)
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: [kept, excluded], merges: merges, bookID: "target", sessionID: "excluded"), 0)
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: [kept, excluded], merges: merges,
                                             from: kept.end, through: kept.end.addingTimeInterval(1)), 7)
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: [kept, excluded], merges: merges,
                                             from: kept.start, through: kept.end), 0)
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: [excluded], merges: merges), 0)
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: [], merges: merges), 0)
    }

    private func turn(id: String, date: Date, bookID: String, sessionID: String, pages: Int) -> AuditEvent {
        AuditEvent(id: id, date: date, kind: "pageTurn", bookID: bookID, sessionID: sessionID,
                   detail: "Synthetic observed pages.",
                   pageTurn: PageTurnEvidence(fromPage: 1, toPage: pages + 1, pagesRead: pages,
                                               visiblePages: 1, layoutSignature: "test"))
    }

    private func adjustment(id: String, date: Date, bookID: String, sessionID: String, pages: Int, recordedAt: Date) -> AuditEvent {
        AuditEvent(id: id, date: date, kind: "manualPageAdjustment", bookID: bookID, sessionID: sessionID,
                   detail: "User correction.",
                   pageAdjustment: ManualPageAdjustmentEvidence(pages: pages, recordedAt: recordedAt, reason: "User correction"))
    }

    private func calendar(in timezoneID: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneID)!
        return calendar
    }
}

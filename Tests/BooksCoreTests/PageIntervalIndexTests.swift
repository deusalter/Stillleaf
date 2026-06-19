import XCTest
@testable import BooksCore

final class PageIntervalIndexTests: XCTestCase {
    func testIndexedMembershipMatchesLinearReferenceAcrossCorrectionsAndMerges() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let intervals = (0..<400).map { index in
            ReadingInterval(sessionID: index % 9 == 0 ? "other" : "long-session",
                bookID: index % 7 == 0 ? "unrelated" : index % 3 == 0 ? "alias" : "book",
                start: base.addingTimeInterval(Double(index * 10)),
                end: base.addingTimeInterval(Double(index * 10 + 8)), duration: 8,
                timezoneID: "UTC", mode: .automatic, disposition: index % 5 == 0 ? .excluded : .credited)
        }
        // Probe starts, ends, gaps and interiors in one long session, including aliased books.
        var events: [AuditEvent] = []
        for index in 0..<800 {
            let date = base.addingTimeInterval(Double(index * 5 + index % 4))
            let book = index % 2 == 0 ? "alias" : "book"
            let evidence = PageTurnEvidence(fromPage: 1, toPage: 2, pagesRead: 1, visiblePages: 1, layoutSignature: "fixture")
            events.append(AuditEvent(date: date, kind: "pageTurn", bookID: book, sessionID: "long-session", detail: "Fixture", pageTurn: evidence))
        }
        let merges = [BookMerge(sourceID: "alias", targetID: "book")]
        func resolve(_ id: String) -> String { id == "alias" ? "book" : id }
        let expected = events.filter { event in
            intervals.contains { interval in
                interval.disposition != .excluded && interval.sessionID == event.sessionID
                    && resolve(interval.bookID) == resolve(event.bookID!)
                    && event.date > interval.start && event.date <= interval.end
            }
        }.count
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: intervals.reversed(), merges: merges), expected)
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: intervals, merges: merges, bookID: "unrelated"), 0)
    }

    func testEarlierOverlappingIntervalCanStillContainEvent() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let intervals = [(0.0, 100.0), (20.0, 30.0), (50.0, 50.0)].map { start, end in
            ReadingInterval(sessionID: "session", bookID: "book", start: base.addingTimeInterval(start),
                end: base.addingTimeInterval(end), duration: end - start, timezoneID: "UTC", mode: .automatic)
        }
        let events = [0.0, 40.0, 50.0, 100.0, 101.0].map { seconds in
            AuditEvent(date: base.addingTimeInterval(seconds), kind: "pageTurn", bookID: "book", sessionID: "session", detail: "Fixture",
                pageTurn: PageTurnEvidence(fromPage: 1, toPage: 2, pagesRead: 1, visiblePages: 1, layoutSignature: "fixture"))
        }
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: intervals, merges: []), 3)
    }
}

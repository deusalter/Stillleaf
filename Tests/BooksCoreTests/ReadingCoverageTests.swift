import XCTest
@testable import BooksCore

final class ReadingCoverageTests: XCTestCase {
    func testBacktrackingPartialOverlapAndNewSession() {
        var coverage = ReadingCoverage()
        func turn(_ a: Int, _ b: Int) -> PageTurnEvidence {
            PageTurnEvidence(fromPage: a, toPage: b, pagesRead: b-a, visiblePages: 1, layoutSignature: "apple")
        }
        XCTAssertEqual(coverage.pages(turn(10, 11), bookID: "b", sessionID: "s"), 1)
        XCTAssertEqual(coverage.pages(turn(10, 11), bookID: "b", sessionID: "s"), 0)
        XCTAssertEqual(coverage.pages(turn(9, 12), bookID: "b", sessionID: "s"), 2)
        XCTAssertEqual(coverage.pages(turn(10, 11), bookID: "b", sessionID: "later"), 1)
    }

    func testLearningAndHidingFooterTotalDoesNotResetCoverage() {
        var coverage = ReadingCoverage()
        var evidence = PageTurnEvidence(fromPage: 10, toPage: 11, pagesRead: 1, visiblePages: 1, layoutSignature: "apple")
        XCTAssertEqual(coverage.pages(evidence, bookID: "b", sessionID: "s"), 1)
        evidence.totalPages = 100
        XCTAssertEqual(coverage.pages(evidence, bookID: "b", sessionID: "s"), 0)
        evidence.totalPages = nil
        XCTAssertEqual(coverage.pages(evidence, bookID: "b", sessionID: "s"), 0)
    }

    func testNativeContentSurvivesReflowAndAccumulatesPartialScreens() {
        var coverage = ReadingCoverage()
        func turn(_ lower: Int, _ upper: Int, page: Int = 1) -> PageTurnEvidence {
            PageTurnEvidence(fromPage: page, toPage: page+1, pagesRead: 1, visiblePages: 1,
                layoutSignature: "native", content: ReaderContentCoverage(resource: "one.xhtml", lower: lower, upper: upper))
        }
        XCTAssertEqual(coverage.pages(turn(0, 100), bookID: "b", sessionID: "s"), 1)
        XCTAssertEqual(coverage.pages(turn(0, 50, page: 8), bookID: "b", sessionID: "s"), 0)
        XCTAssertEqual(coverage.pages(turn(50, 150), bookID: "b", sessionID: "s"), 0)
        XCTAssertEqual(coverage.pages(turn(100, 200), bookID: "b", sessionID: "s"), 1)
        XCTAssertEqual(coverage.pages(turn(0, 100), bookID: "b", sessionID: "later"), 1)
    }

    func testDateFilterDoesNotRecreditEarlierCoverageAndRoundTripPreservesIt() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = ReadingInterval(sessionID: "s", bookID: "b", start: date, end: date.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .automatic)
        let evidence = PageTurnEvidence(fromPage: 10, toPage: 11, pagesRead: 1, visiblePages: 1, layoutSignature: "apple")
        let events = [1.0, 3.0].map { AuditEvent(date: date.addingTimeInterval($0), kind: "pageTurn", bookID: "b", sessionID: "s", detail: "test", pageTurn: evidence) }
        let decoded = try JSONDecoder().decode([AuditEvent].self, from: JSONEncoder().encode(events))
        XCTAssertEqual(PageStatistics.pages(events: decoded, effectiveIntervals: [interval], merges: []), 1)
        XCTAssertEqual(PageStatistics.pages(events: decoded, effectiveIntervals: [interval], merges: [], from: date.addingTimeInterval(2)), 0)
        var excluded = interval; excluded.disposition = .excluded
        XCTAssertEqual(PageStatistics.pages(events: decoded, effectiveIntervals: [excluded], merges: []), 0)
    }

    func testDisplaySplitKeepsSessionCoverageForPagesPaceAndVisibility() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let intervals = (0..<3).map { index in
            ReadingInterval(id: "i\(index)", sessionID: "s", bookID: "b",
                start: date.addingTimeInterval(Double(index * 10)), end: date.addingTimeInterval(Double(index * 10 + 10)),
                duration: 10, timezoneID: "UTC", mode: .automatic, disposition: index == 1 ? .excluded : .credited)
        }
        let evidence = PageTurnEvidence(fromPage: 10, toPage: 11, pagesRead: 1, visiblePages: 1, layoutSignature: "apple")
        let events = [5.0, 25.0].map { AuditEvent(date: date.addingTimeInterval($0), kind: "pageTurn", bookID: "b", sessionID: "s", detail: "test", pageTurn: evidence) }
        let groups = ReadingSessionGrouping.groups(intervals: intervals, merges: [])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map { PageStatistics.pages(events: events, effectiveIntervals: intervals, merges: [], within: $0.intervals) }, [1, 0])
        XCTAssertEqual(PageStatistics.pagesPerMinute(events: events, effectiveIntervals: intervals, merges: [], within: groups[0].intervals), 6)
        XCTAssertNil(PageStatistics.pagesPerMinute(events: events, effectiveIntervals: intervals, merges: [], within: groups[1].intervals))
        XCTAssertEqual(ReadingSessionGrouping.visibleGroups(groups, events: events, merges: []).map(\.id), [groups[0].id])
        let surviving = intervals.filter { $0.disposition != .excluded }
        let explicit = ReadingSessionGrouping.groups(intervals: surviving, merges: [], breakBeforeIntervalIDs: [surviving[1].id])
        XCTAssertEqual(ReadingSessionGrouping.visibleGroups(explicit, events: events, merges: []).count, 1)
    }

    func testWholeBookFractionUsesMeasuredContentDenominator() throws {
        let position = try JSONDecoder().decode(NativeReaderPosition.self, from: Data(#"{"href":"two.xhtml","page":3,"totalPages":9,"visiblePages":1,"bookOffset":900,"bookTotal":1200}"#.utf8))
        let observation = try XCTUnwrap(position.observation(bookID: "b", spine: ["one.xhtml", "two.xhtml"]))
        XCTAssertEqual(observation.fraction, 0.75)
        XCTAssertNil(observation.totalPages)
        var invalid = position; invalid.bookTotal = 0
        XCTAssertNil(invalid.observation(bookID: "b", spine: ["one.xhtml", "two.xhtml"]))
    }

    func testNativePositionIsChapterScopedAndNeverManufacturesWholeBookPercentage() throws {
        let data = Data(#"{"href":"one.xhtml","page":8,"totalPages":20,"visiblePages":1,"lower":120,"upper":320}"#.utf8)
        let position = try JSONDecoder().decode(NativeReaderPosition.self, from: data)
        let observation = try XCTUnwrap(position.observation(bookID: "b", spine: ["one.xhtml", "two.xhtml"]))
        XCTAssertEqual(observation.location, "Chapter 1 of 2 · Page 8 of 20")
        XCTAssertNil(observation.page); XCTAssertNil(observation.totalPages); XCTAssertNil(observation.fraction)
        XCTAssertTrue(observation.reliable)
        XCTAssertEqual(position.forwardCoverage(spine: ["one.xhtml"])?.content?.lower, 120)
        XCTAssertNil(position.observation(bookID: "b", spine: ["other.xhtml"]))
    }
    func testNewScreenEvidenceCreditsOneSpreadAndPreservesLegacyEvidence() throws {
        let legacyJSON = Data(#"{"href":"one.xhtml","page":3,"totalPages":7,"visiblePages":2,"lower":0,"upper":200}"#.utf8)
        let legacy = try JSONDecoder().decode(NativeReaderPosition.self, from: legacyJSON)
        XCTAssertEqual(legacy.forwardCoverage(spine: ["one.xhtml"])?.pagesRead, 2)
        var screen = legacy
        screen.pageUnit = "screen"; screen.visiblePages = 1; screen.totalPages = 4; screen.page = 2
        let evidence = try XCTUnwrap(screen.forwardCoverage(spine: ["one.xhtml"]))
        XCTAssertEqual(evidence.pagesRead, 1)
        XCTAssertEqual(evidence.visiblePages, 1)
        XCTAssertEqual(evidence.layoutSignature, "stillleaf-screen-v2")
        XCTAssertEqual(evidence.content, legacy.content)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = ReadingInterval(sessionID: "s", bookID: "b", start: date, end: date.addingTimeInterval(20), duration: 20, timezoneID: "UTC", mode: .automatic)
        func event(_ evidence: PageTurnEvidence, at seconds: Double) -> AuditEvent {
            AuditEvent(date: date.addingTimeInterval(seconds), kind: "pageTurn", bookID: "b", sessionID: "s", detail: "Screen traversal", pageTurn: evidence)
        }
        // Goals/history use the same coverage-derived count. Reflowing coordinates
        // does not let another turn over the same content earn a phantom page.
        let original = [event(evidence, at: 1)]
        screen.page = 3; screen.totalPages = 8
        let reflowed = try XCTUnwrap(screen.forwardCoverage(spine: ["one.xhtml"]))
        let events = original + [event(reflowed, at: 2)]
        XCTAssertEqual(PageStatistics.pages(events: events, effectiveIntervals: [interval], merges: []), 1)
        XCTAssertEqual(PageStatistics.snapshot(events: events, effectiveIntervals: [interval], merges: []).pages(), 1)
        let encoded = try JSONEncoder().encode(events)
        XCTAssertEqual(try JSONDecoder().decode([AuditEvent].self, from: encoded), events)
        let legacyEvidence = try XCTUnwrap(legacy.forwardCoverage(spine: ["one.xhtml"]))
        XCTAssertEqual(try JSONDecoder().decode(PageTurnEvidence.self, from: JSONEncoder().encode(legacyEvidence)), legacyEvidence)
        let mixed = [event(legacyEvidence, at: 1), event(evidence, at: 2)]
        XCTAssertEqual(PageStatistics.pages(events: mixed, effectiveIntervals: [interval], merges: []), 2, "Legacy audit credit stays unchanged; a unit toggle cannot recredit its text")
        screen.visiblePages = 2
        XCTAssertFalse(screen.isValid(spine: ["one.xhtml"]), "New screen payloads cannot inflate credit to two")
    }

}

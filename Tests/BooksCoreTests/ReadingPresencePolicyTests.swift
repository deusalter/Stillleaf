import XCTest
@testable import BooksCore

final class ReadingPresencePolicyTests: XCTestCase {
    private let book = BookRecord(id: "fixture", title: "Synthetic Reading")
    private func snapshot(_ phase: TrackerPhase, _ reason: PauseReason? = nil) -> TrackerSnapshot {
        var result = TrackerSnapshot(); result.book = book; result.phase = phase; result.pauseReason = reason
        return result
    }

    func testBackgroundRemainsPausedUntilExactPageInactivityBoundary() {
        var policy = ReadingPresencePolicy()
        policy.observe(bookID: book.id, navigationToken: "page:52", relevantActivity: false, uptime: 100)
        XCTAssertEqual(policy.state(for: snapshot(.reading), book: book, enabled: true, readerOpen: true, uptime: 101), .reading)
        XCTAssertEqual(policy.state(for: snapshot(.paused, .background), book: book, enabled: true, readerOpen: true, uptime: 1299.99), .paused)
        XCTAssertEqual(policy.state(for: snapshot(.paused, .background), book: book, enabled: true, readerOpen: true, uptime: 1300), .hidden)
        policy.observe(bookID: book.id, navigationToken: "page:52", relevantActivity: true, uptime: 1301)
        XCTAssertEqual(policy.state(for: snapshot(.reading), book: book, enabled: true, readerOpen: true, uptime: 1301), .hidden)
        policy.observe(bookID: book.id, navigationToken: "page:54", relevantActivity: false, uptime: 1302)
        XCTAssertEqual(policy.state(for: snapshot(.reading), book: book, enabled: true, readerOpen: true, uptime: 1302), .reading)
    }

    func testClosingReaderHidesImmediatelyAndReopenNeedsFreshActivity() {
        var policy = ReadingPresencePolicy()
        policy.observe(bookID: book.id, navigationToken: "page:52", relevantActivity: false, uptime: 100)
        XCTAssertEqual(policy.state(for: snapshot(.paused, .background), book: book, enabled: true,
                                    readerOpen: true, uptime: 101), .paused)
        XCTAssertEqual(policy.state(for: snapshot(.paused, .background), book: book, enabled: true,
                                    readerOpen: false, uptime: 102), .hidden)
        XCTAssertEqual(policy.state(for: snapshot(.paused, .background), book: book, enabled: true,
                                    readerOpen: true, uptime: 103), .hidden)
        policy.observe(bookID: book.id, navigationToken: "page:52", relevantActivity: false, uptime: 104)
        XCTAssertEqual(policy.state(for: snapshot(.reading), book: book, enabled: true,
                                    readerOpen: true, uptime: 105), .reading)
    }

    func testQuittingReaderWhileReadingHidesImmediately() {
        var policy = ReadingPresencePolicy()
        policy.observe(bookID: book.id, navigationToken: "page:1", relevantActivity: false, uptime: 1)
        XCTAssertEqual(policy.state(for: snapshot(.reading), book: book, enabled: true,
                                    readerOpen: true, uptime: 2), .reading)
        XCTAssertEqual(policy.state(for: snapshot(.reading), book: book, enabled: true,
                                    readerOpen: false, uptime: 3), .hidden)
        policy.observe(bookID: book.id, navigationToken: nil, relevantActivity: true, uptime: 4)
        var manual = snapshot(.reading); manual.mode = .manual
        XCTAssertEqual(policy.state(for: manual, book: book, enabled: true,
                                    readerOpen: false, uptime: 5), .hidden)
    }

    func testMissingPageSampleDoesNotTurnPointerMotionIntoPageTurn() {
        var policy = ReadingPresencePolicy(inactivityTimeout: 20)
        policy.observe(bookID: book.id, navigationToken: "page:1", relevantActivity: false, uptime: 1)
        policy.observe(bookID: book.id, navigationToken: nil, relevantActivity: true, uptime: 20)
        XCTAssertEqual(policy.state(for: snapshot(.paused, .noReadingWindow), book: book, enabled: true, readerOpen: true, uptime: 21), .hidden)
    }

    func testUnsupportedReaderUsesOnlyVerifiedReadingActivityFallback() {
        var policy = ReadingPresencePolicy(inactivityTimeout: 20)
        policy.observe(bookID: book.id, navigationToken: nil, relevantActivity: false, uptime: 1)
        policy.observe(bookID: book.id, navigationToken: nil, relevantActivity: true, uptime: 19)
        XCTAssertEqual(policy.state(for: snapshot(.paused, .background), book: book, enabled: true, readerOpen: true, uptime: 38), .paused)
        XCTAssertEqual(policy.state(for: snapshot(.paused, .background), book: book, enabled: true, readerOpen: true, uptime: 39), .hidden)
    }

    func testPrivacyStopsImmediatelyForgetTheCard() {
        for reason in [PauseReason.disabled, .locked, .displayAsleep, .permissionLost, .excludedBook, .stopped, .captureFailure, .recovery, .clockDiscontinuity] {
            var policy = ReadingPresencePolicy()
            policy.observe(bookID: book.id, navigationToken: "1", relevantActivity: true, uptime: 1)
            XCTAssertEqual(policy.state(for: snapshot(.paused, reason), book: book, enabled: true, readerOpen: true, uptime: 2), .hidden)
            XCTAssertEqual(policy.state(for: snapshot(.paused, .background), book: book, enabled: true, readerOpen: true, uptime: 3), .hidden)
        }
        var policy = ReadingPresencePolicy()
        policy.observe(bookID: book.id, navigationToken: "1", relevantActivity: true, uptime: 1)
        XCTAssertEqual(policy.state(for: snapshot(.reading), book: book, enabled: false, readerOpen: true, uptime: 2), .hidden)
        XCTAssertEqual(policy.state(for: snapshot(.reading), book: book, enabled: true, readerOpen: true, uptime: 3), .hidden)
        policy.observe(bookID: book.id, navigationToken: "1", relevantActivity: true, uptime: 4)
        var excluded = book; excluded.sharingExcluded = true
        XCTAssertEqual(policy.state(for: snapshot(.paused, .background), book: excluded, enabled: true, readerOpen: true, uptime: 5), .hidden)
        XCTAssertEqual(policy.state(for: snapshot(.paused, .background), book: book, enabled: true, readerOpen: true, uptime: 6), .hidden)
        policy.observe(bookID: book.id, navigationToken: "1", relevantActivity: false, uptime: 7)
        XCTAssertEqual(policy.state(for: snapshot(.reading), book: book, enabled: true, readerOpen: true, uptime: 8), .reading)
    }

    func testSharingResetCannotChangeIndependentReadingEvidence() {
        var reading = ReadingActivityEvidence()
        var presence = ReadingPresencePolicy()
        XCTAssertTrue(reading.observe(bookID: book.id, navigationToken: "1", relevantActivity: false))
        presence.observe(bookID: book.id, navigationToken: "1", relevantActivity: false, uptime: 1)
        XCTAssertEqual(presence.state(for: snapshot(.reading), book: book, enabled: false, readerOpen: true, uptime: 2), .hidden)
        XCTAssertFalse(reading.observe(bookID: book.id, navigationToken: "1", relevantActivity: true))
        XCTAssertFalse(reading.observe(bookID: book.id, navigationToken: nil, relevantActivity: true))
        XCTAssertTrue(reading.observe(bookID: book.id, navigationToken: "2", relevantActivity: false))
    }

    func testSwitchingBooksStartsNewWindowAndClockRollbackClears() {
        var policy = ReadingPresencePolicy(inactivityTimeout: 20)
        policy.observe(bookID: book.id, navigationToken: "1", relevantActivity: false, uptime: 100)
        let other = BookRecord(id: "other", title: "Another Fixture")
        policy.observe(bookID: other.id, navigationToken: "1", relevantActivity: false, uptime: 500)
        XCTAssertEqual(policy.state(for: snapshot(.reading), book: other, enabled: true, readerOpen: true, uptime: 501), .reading)
        XCTAssertEqual(policy.state(for: snapshot(.reading), book: other, enabled: true, readerOpen: true, uptime: 499), .hidden)
    }
}

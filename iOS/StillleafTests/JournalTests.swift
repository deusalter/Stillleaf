import XCTest
import BooksCore
import BooksPlatform
@testable import Stillleaf

/// The journal on iOS: the Mac's evidence model, credited only in the foreground with the reader ready.
@MainActor
final class JournalTests: XCTestCase {
    private var scratch: Scratch!
    private var clock: ManualClock!
    private var journal: Journal!
    private var edition: Edition!

    override func setUp() async throws {
        scratch = try Scratch()
        clock = ManualClock()
        journal = try scratch.journal(clock: clock)
        await journal.importEPUBs([try scratch.epub()])
        edition = try XCTUnwrap(journal.editions.values.first, journal.notice?.message ?? "no edition")
    }

    override func tearDown() async throws {
        journal = nil; edition = nil; clock = nil; scratch = nil
    }

    private func read(seconds: Int) {
        for _ in 0..<seconds { clock.advance(1); journal.tick() }
    }

    private func departure(page: Int = 1) throws -> NativeReaderPosition {
        let json: [String: Any] = ["href": edition.publication.spine[0], "page": page, "totalPages": 6, "visiblePages": 1,
                                   "pageUnit": "screen", "bookOffset": page * 100, "bookTotal": 1_000, "lower": page * 100, "upper": page * 100 + 100]
        return try JSONDecoder().decode(NativeReaderPosition.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testImportRegistersOneJournalBookPerEdition() async throws {
        XCTAssertEqual(journal.book(edition.bookID)?.source, "stillleaf-epub")
        XCTAssertEqual(journal.book(edition.bookID)?.title, "A Synthetic Garden")
        XCTAssertNotNil(edition.coverURL.flatMap { CoverThumbnails.thumbnail($0, maxPixels: 64) })
        await journal.importEPUBs([try scratch.epub()])
        XCTAssertEqual(journal.editions.count, 1)
        XCTAssertEqual(journal.history.librarySummary.books.count, 1)
    }

    func testTimeIsCreditedOnlyWhileTheReaderIsReadyAndTheSceneIsActive() throws {
        journal.readerOpened(bookID: edition.bookID)
        read(seconds: 5)
        XCTAssertEqual(journal.tracker.phase, .paused, "nothing before the renderer is ready")
        XCTAssertEqual(journal.pauseReason, .noReadingWindow)

        journal.readerBecameReady(bookID: edition.bookID)
        read(seconds: 30)
        XCTAssertEqual(journal.tracker.phase, .reading)
        XCTAssertEqual(journal.tracker.sessionSeconds, 30, accuracy: 0.01)
        let session = journal.tracker.sessionID

        journal.sceneActivityChanged(active: false)
        XCTAssertEqual(journal.tracker.pauseReason, .background, "leaving the foreground pauses at once")
        read(seconds: 60)
        XCTAssertEqual(journal.tracker.phase, .paused)

        journal.sceneActivityChanged(active: true)
        read(seconds: 1)
        XCTAssertEqual(journal.tracker.sessionID, session, "a short interruption resumes the same session")

        let before = journal.tracker.sessionSeconds
        clock.advance(600); journal.tick()
        XCTAssertLessThanOrEqual(journal.tracker.sessionSeconds, before + 1, "an unseen suspension is never credited")

        journal.readerClosed(bookID: edition.bookID)
        XCTAssertEqual(journal.tracker.phase, .paused)
        XCTAssertEqual(journal.history.today.creditedSeconds, 31, accuracy: 1)
    }

    func testTrackingOffAndExcludedBooksRecordNothing() {
        journal.setTrackingEnabled(false)
        journal.readerOpened(bookID: edition.bookID); journal.readerBecameReady(bookID: edition.bookID)
        read(seconds: 10)
        XCTAssertEqual(journal.pauseReason, .disabled)
        journal.readerClosed(bookID: edition.bookID)
        journal.setTrackingEnabled(true)

        journal.setTrackingExcluded(true, for: edition.bookID)
        journal.readerOpened(bookID: edition.bookID); journal.readerBecameReady(bookID: edition.bookID)
        read(seconds: 10)
        XCTAssertEqual(journal.tracker.pauseReason, .excludedBook)
        journal.readerClosed(bookID: edition.bookID)
        XCTAssertEqual(journal.history.today.creditedSeconds, 0)
    }

    func testForwardCoverageCountsPagesOnlyInsideACreditedSession() throws {
        let evidence = try XCTUnwrap(try departure().forwardCoverage(spine: edition.publication.spine))
        journal.readerTraversed(bookID: edition.bookID, evidence: evidence)
        journal.readerOpened(bookID: edition.bookID); journal.readerBecameReady(bookID: edition.bookID)
        read(seconds: 3)
        journal.readerTraversed(bookID: edition.bookID, evidence: evidence)
        journal.readerTraversed(bookID: edition.bookID, evidence: try XCTUnwrap(try departure(page: 2).forwardCoverage(spine: edition.publication.spine)))
        journal.readerMoved(try XCTUnwrap(try departure(page: 3).observation(bookID: edition.bookID, spine: edition.publication.spine, date: clock.date)))
        journal.readerClosed(bookID: edition.bookID)
        XCTAssertEqual(journal.pagesRead(bookID: edition.bookID), 2)
        XCTAssertEqual(journal.position(bookID: edition.bookID)?.location, "Chapter 1 of 3 · Page 3 of 6")
    }

    func testManualEntriesAreValidatedLikeTheMac() {
        let paper = BookRecord(id: "manual:" + UUID().uuidString, title: "Paper Book", observedAt: clock.date)
        clock.advance(3_600)
        XCTAssertTrue(journal.logReading(book: paper, end: clock.date, minutes: 25, pages: 12))
        XCTAssertFalse(journal.logReading(book: paper, end: clock.date, minutes: 10, pages: nil), "overlap rejected")
        XCTAssertFalse(journal.logReading(book: paper, end: clock.date.addingTimeInterval(7_200), minutes: 10, pages: nil), "future rejected")
        XCTAssertEqual(journal.history.today.creditedSeconds, 1_500, accuracy: 1)
        XCTAssertEqual(journal.pagesRead(bookID: paper.id), 12)
    }

    func testCompletionRatingReviewAndGoalsWriteMacEvidence() throws {
        XCTAssertEqual(journal.dailyGoal?.resolvedUnit, .pages)
        XCTAssertEqual(journal.dailyGoal?.pages, 20)
        XCTAssertTrue(journal.markFinished(edition.bookID))
        XCTAssertNotNil(journal.finished(bookID: edition.bookID))
        XCTAssertTrue(journal.saveRating(3.75, for: edition.bookID))
        XCTAssertFalse(journal.saveRating(3.8, for: edition.bookID))
        XCTAssertTrue(journal.saveReview("  Quiet and good.  ", for: edition.bookID))
        XCTAssertEqual(journal.review(bookID: edition.bookID), "Quiet and good.")
        XCTAssertTrue(journal.saveGoals(unit: .minutes, pages: 30, minutes: 45, annualBooks: 12))
        XCTAssertEqual(journal.dailyGoal?.resolvedUnit, .minutes)
        XCTAssertEqual(journal.history.annualBookGoal, 12)
        XCTAssertEqual(journal.history.annualBooksFinished, 1)
        let kinds = Set(try ReadingStore(url: journal.paths.history).archive().events.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: ["bookCompleted", "bookRated", "bookReviewed", "annualGoalChanged"]))
    }

    func testExportsRoundTripInMacFormats() throws {
        journal.readerOpened(bookID: edition.bookID); journal.readerBecameReady(bookID: edition.bookID)
        read(seconds: 20)
        journal.readerClosed(bookID: edition.bookID)
        XCTAssertTrue(journal.saveReview("Kept across devices.", for: edition.bookID))

        let json = try journal.exportJSON()
        let csv = try journal.exportCSV()
        let backup = try journal.backup()
        for table in ["intervals.csv", "effective_intervals.csv", "books.csv", "goals.csv", "events.csv", "progress.csv", "corrections.csv"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: csv.appendingPathComponent(table).path), table)
        }

        // The Mac imports the same archive through the same store.
        let mac = try ReadingStore(url: scratch.url("mac.sqlite"))
        try mac.importJSON(from: json)
        XCTAssertEqual(try mac.archive().books.map(\.id), [edition.bookID])

        let merged = try scratch.journal("merged", clock: ManualClock())
        XCTAssertTrue(merged.importJSON(from: json))
        XCTAssertTrue(merged.importJSON(from: json), "duplicate-safe")
        XCTAssertEqual(merged.history.intervals.count, journal.history.intervals.count)
        XCTAssertEqual(merged.review(bookID: edition.bookID), "Kept across devices.")

        let restored = try scratch.journal("restored", clock: ManualClock())
        XCTAssertTrue(restored.restore(from: backup))
        XCTAssertEqual(restored.history.intervals.count, journal.history.intervals.count)
    }

    func testRemovingTheDownloadKeepsHistoryAndDeletingRemovesBoth() async throws {
        let files = edition.directory
        XCTAssertTrue(journal.removeDownload(edition.bookID), journal.notice?.message ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.path))
        XCTAssertNotNil(journal.book(edition.bookID))

        await journal.importEPUBs([try scratch.epub()])
        XCTAssertTrue(journal.deleteBook(edition.bookID), journal.notice?.message ?? "")
        XCTAssertNil(journal.book(edition.bookID))
        XCTAssertTrue(journal.editions.isEmpty)

        XCTAssertTrue(journal.deleteAllData())
        XCTAssertTrue(journal.history.books.isEmpty)
        XCTAssertNotNil(journal.dailyGoal, "a default goal is restored")
    }
}

import XCTest
@testable import BooksCore

final class ReadingGoalsTests: XCTestCase {
    func testLegacyGoalDecodingResolvesPagesWhenPresentOtherwiseMinutes() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let minutes = try decoder.decode(GoalChange.self, from: Data(
            #"{"id":"minutes","effectiveDay":"2026-01-01","minutes":20,"createdAt":1767225600000}"#.utf8))
        let pages = try decoder.decode(GoalChange.self, from: Data(
            #"{"id":"pages","effectiveDay":"2026-01-01","minutes":20,"pages":12,"createdAt":1767225600000}"#.utf8))
        XCTAssertNil(minutes.primaryUnit)
        XCTAssertEqual(minutes.resolvedUnit, .minutes)
        XCTAssertNil(pages.primaryUnit)
        XCTAssertEqual(pages.resolvedUnit, .pages)
    }

    func testDailyProgressUsesHistoricalPrimaryModeAndRetainsIndependentTargets() {
        let goals = [
            GoalChange(id: "minutes", effectiveDay: "2026-01-01", minutes: 30, pages: 12,
                       primaryUnit: .minutes),
            GoalChange(id: "pages", effectiveDay: "2026-01-03", minutes: 30, pages: 12,
                       primaryUnit: .pages),
            GoalChange(id: "minutes-again", effectiveDay: "2026-01-05", minutes: 30, pages: 12,
                       primaryUnit: .minutes)
        ]
        let minuteDay = ReadingGoals.daily(day: "2026-01-02", pages: 20, creditedSeconds: 900, goals: goals)
        XCTAssertEqual(minuteDay.unit, .minutes)
        XCTAssertEqual(minuteDay.value, 15)
        XCTAssertEqual(minuteDay.target, 30)
        XCTAssertEqual(minuteDay.fraction, 0.5)
        XCTAssertFalse(minuteDay.reached)

        let pageDay = ReadingGoals.daily(day: "2026-01-04", pages: 12, creditedSeconds: 0, goals: goals)
        XCTAssertEqual(pageDay.unit, .pages)
        XCTAssertEqual(pageDay.value, 12)
        XCTAssertEqual(pageDay.target, 12)
        XCTAssertEqual(pageDay.fraction, 1)
        XCTAssertTrue(pageDay.reached)

        let switchedBack = ReadingGoals.daily(day: "2026-01-06", pages: 0, creditedSeconds: 1_800, goals: goals)
        XCTAssertEqual(switchedBack.unit, .minutes)
        XCTAssertEqual(switchedBack.target, 30)
        XCTAssertTrue(switchedBack.reached)
    }

    func testSameDayGoalUsesArchiveOrderLikeExistingDailyStatistics() {
        let goals = [
            GoalChange(id: "first", effectiveDay: "2026-01-01", minutes: 10, primaryUnit: .minutes),
            GoalChange(id: "second", effectiveDay: "2026-01-01", minutes: 40, primaryUnit: .minutes)
        ]
        XCTAssertEqual(ReadingGoals.daily(day: "2026-01-01", pages: 0, creditedSeconds: 0,
                                          goals: goals).target, 40)
    }

    func testAnnualTargetLatestTimestampThenIDAndNoGoal() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            annual(id: "a", date: date, year: 2027, books: 10),
            annual(id: "z", date: date, year: 2027, books: 20),
            annual(id: "later", date: date.addingTimeInterval(1), year: 2027, books: nil),
            annual(id: "other", date: date.addingTimeInterval(2), year: 2028, books: 30)
        ]
        XCTAssertNil(ReadingGoals.annualTarget(year: 2026, events: events))
        XCTAssertNil(ReadingGoals.annualTarget(year: 2027, events: events))
        XCTAssertEqual(ReadingGoals.annualTarget(year: 2028, events: events), 30)
        XCTAssertEqual(ReadingGoals.annualTarget(year: 2027, events: Array(events.prefix(2))), 20)
    }

    func testFinishedCountUsesConfiguredYearBoundaryDedupCorrectionsAndNow() {
        let books = [
            BookRecord(id: "source", title: "Source"),
            BookRecord(id: "target", title: "Target"),
            BookRecord(id: "cleared", title: "Cleared"),
            BookRecord(id: "future", title: "Future"),
            BookRecord(id: "undated", title: "Undated")
        ]
        let boundary = isoDate("2027-01-01T00:30:00Z") // Still 2026 in Los Angeles.
        let now = isoDate("2027-06-01T00:00:00Z")
        let events = [
            completion(id: "source-done", bookID: "source", observedAt: boundary, finishedAt: boundary, imported: false),
            completion(id: "target-done", bookID: "target", observedAt: boundary, finishedAt: boundary, imported: false),
            completion(id: "cleared-old", bookID: "cleared", observedAt: boundary, finishedAt: boundary, imported: false),
            completion(id: "cleared-new", bookID: "cleared", observedAt: boundary.addingTimeInterval(1), finishedAt: nil, imported: false),
            completion(id: "future", bookID: "future", observedAt: isoDate("2028-01-01T00:00:00Z"),
                       finishedAt: isoDate("2027-12-01T00:00:00Z"), imported: false),
            completion(id: "undated", bookID: "undated", observedAt: boundary, finishedAt: nil, imported: false)
        ]
        let merges = [BookMerge(sourceID: "source", targetID: "target")]
        XCTAssertEqual(ReadingGoals.finishedCount(year: 2026, timezoneID: "America/Los_Angeles",
                                                   books: books, events: events, merges: merges, now: now), 1)
        XCTAssertEqual(ReadingGoals.finishedCount(year: 2027, timezoneID: "UTC", books: books,
                                                   events: events, merges: merges, now: now), 1)
    }

    func testFinishedCountSelectsCompletionAfterCanonicalizingMergedIDs() {
        let books = [
            BookRecord(id: "source", title: "Source copy"),
            BookRecord(id: "target", title: "Canonical copy")
        ]
        let merge = [BookMerge(sourceID: "source", targetID: "target")]
        let oldFinish = isoDate("2026-06-01T00:00:00Z")
        let correctedFinish = isoDate("2027-06-01T00:00:00Z")
        let now = isoDate("2028-01-01T00:00:00Z")
        let importedCorrections = [
            completion(id: "old", bookID: "source", observedAt: oldFinish, finishedAt: oldFinish, imported: true),
            completion(id: "corrected", bookID: "target", observedAt: correctedFinish,
                       finishedAt: correctedFinish, imported: true)
        ]
        XCTAssertEqual(ReadingGoals.finishedCount(year: 2026, timezoneID: "UTC", books: books,
                                                   events: importedCorrections, merges: merge, now: now), 0)
        XCTAssertEqual(ReadingGoals.finishedCount(year: 2027, timezoneID: "UTC", books: books,
                                                   events: importedCorrections, merges: merge, now: now), 1)

        let manualOverride = importedCorrections + [
            completion(id: "manual", bookID: "source", observedAt: correctedFinish.addingTimeInterval(1),
                       finishedAt: oldFinish, imported: false)
        ]
        XCTAssertEqual(ReadingGoals.finishedCount(year: 2026, timezoneID: "UTC", books: books,
                                                   events: manualOverride, merges: merge, now: now), 1)
        XCTAssertEqual(ReadingGoals.finishedCount(year: 2027, timezoneID: "UTC", books: books,
                                                   events: manualOverride, merges: merge, now: now), 0)
    }

    func testAnnualGoalReviewAndGoalModePersistThroughJSONAndCSV() throws {
        let source = try makeStore()
        let book = BookRecord(id: "book", title: "Synthetic")
        try source.saveBook(book)
        let goal = GoalChange(id: "goal", effectiveDay: "2027-01-01", minutes: 25, pages: 15,
                              createdAt: Date(timeIntervalSince1970: 1_800_000_000), primaryUnit: .pages)
        try source.setGoal(goal)
        try source.appendEvent(annual(id: "annual", date: Date(timeIntervalSince1970: 1_800_000_000),
                                      year: 2027, books: 24))
        try source.appendEvent(review(id: "review", date: Date(timeIntervalSince1970: 1_800_000_001),
                                      bookID: book.id, text: "A careful, local review."))

        let directory = temporaryDirectory()
        let json = directory.appendingPathComponent("history.json")
        try source.exportJSON(to: json)
        let destination = try makeStore()
        try destination.importJSON(from: json)
        let archive = try destination.archive()
        XCTAssertEqual(archive.goals.first, goal)
        XCTAssertEqual(archive.events.first { $0.id == "annual" }?.annualGoal,
                       AnnualGoalEvidence(year: 2027, books: 24))
        XCTAssertEqual(BookHistory.review(bookID: book.id, events: archive.events), "A careful, local review.")

        let csv = directory.appendingPathComponent("csv", isDirectory: true)
        try destination.exportCSV(to: csv)
        let goalsCSV = try String(contentsOf: csv.appendingPathComponent("goals.csv"))
        let eventsCSV = try String(contentsOf: csv.appendingPathComponent("events.csv"))
        XCTAssertTrue(goalsCSV.contains("primary_unit"))
        XCTAssertTrue(goalsCSV.contains("pages"))
        XCTAssertTrue(eventsCSV.contains("annual_goal_year,annual_goal_state,annual_goal_books,review_state,review_text"))
        XCTAssertTrue(eventsCSV.contains("A careful, local review."))
    }

    func testReviewLatestCorrectionClearAndValidation() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            review(id: "first", date: date, bookID: "book", text: "First"),
            review(id: "second", date: date, bookID: "book", text: "Second")
        ]
        XCTAssertEqual(BookHistory.review(bookID: "book", events: events), "Second")
        XCTAssertNil(BookHistory.review(bookID: "book", events: events + [
            review(id: "clear", date: date.addingTimeInterval(1), bookID: "book", text: nil)
        ]))

        let store = try makeStore()
        try store.saveBook(BookRecord(id: "book", title: "Synthetic"))
        try store.appendEvent(review(id: "valid", date: date, bookID: "book",
                                     text: String(repeating: "é", count: 50_000)))
        XCTAssertThrowsError(try store.appendEvent(review(id: "too-long", date: date, bookID: "book",
                                                          text: String(repeating: "x", count: 50_001))))
        XCTAssertThrowsError(try store.appendEvent(AuditEvent(id: "missing", date: date, kind: "bookReviewed",
                                                               bookID: "book", detail: "Missing evidence")))
        XCTAssertThrowsError(try store.appendEvent(AuditEvent(id: "bad-year", date: date,
                                                               kind: "annualGoalChanged", detail: "Bad",
                                                               annualGoal: AnnualGoalEvidence(year: 0, books: 1))))
        XCTAssertThrowsError(try store.appendEvent(AuditEvent(id: "bad-target", date: date,
                                                               kind: "annualGoalChanged", detail: "Bad",
                                                               annualGoal: AnnualGoalEvidence(year: 2027, books: 10_001))))
    }

    func testLegacyEventDecodesWithoutGoalOrReviewEvidence() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let event = try decoder.decode(AuditEvent.self, from: Data(
            #"{"id":"legacy","date":1800000000000,"kind":"legacy","detail":"old"}"#.utf8))
        XCTAssertNil(event.annualGoal)
        XCTAssertNil(event.review)
    }

    func testJointGoalSaveRollsBackDailyOnAnnualConflict() throws {
        let store = try makeStore()
        let original = annual(id: "fixed", date: Date(), year: 2027, books: 12)
        try store.appendEvent(original)
        var conflict = original
        conflict.annualGoal = AnnualGoalEvidence(year: 2027, books: 24)
        XCTAssertThrowsError(try store.setReadingGoals(daily: GoalChange(effectiveDay: "2027-01-01", minutes: 30, pages: 20, primaryUnit: .minutes), annual: conflict))
        let archive = try store.archive()
        XCTAssertTrue(archive.goals.isEmpty)
        XCTAssertEqual(ReadingGoals.annualTarget(year: 2027, events: archive.events), 12)
    }

    private func annual(id: String, date: Date, year: Int, books: Int?) -> AuditEvent {
        AuditEvent(id: id, date: date, kind: "annualGoalChanged", detail: "Annual goal changed.",
                   annualGoal: AnnualGoalEvidence(year: year, books: books))
    }

    private func completion(id: String, bookID: String, observedAt: Date, finishedAt: Date?,
                            imported: Bool) -> AuditEvent {
        AuditEvent(id: id, date: observedAt, kind: "bookCompleted", bookID: bookID, detail: "Completion",
                   completion: BookCompletionEvidence(finishedAt: finishedAt,
                                                       source: imported ? "Catalog" : "User edit",
                                                       imported: imported))
    }

    private func review(id: String, date: Date, bookID: String, text: String?) -> AuditEvent {
        AuditEvent(id: id, date: date, kind: "bookReviewed", bookID: bookID, detail: "Review changed.",
                   review: BookReviewEvidence(text: text))
    }

    private func makeStore() throws -> ReadingStore {
        try ReadingStore(url: temporaryDirectory().appendingPathComponent("history.sqlite"))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isoDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

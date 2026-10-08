import XCTest
@testable import BooksCore

final class ManualReadingEntryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let zone = "UTC"

    private func entry(end: Date? = nil, minutes: Double = 0, pages: ManualPages? = nil, total: Int? = nil) -> ManualReadingEntry {
        ManualReadingEntry(bookID: "book", end: end ?? now.addingTimeInterval(-3_600), seconds: minutes * 60,
                           pages: pages, totalPages: total, timezoneID: zone)
    }

    func testEntryNeedsTimeOrPages() {
        XCTAssertEqual(entry().issue(existing: [], now: now), .nothingToLog)
        XCTAssertNil(entry(minutes: 30).issue(existing: [], now: now))
        XCTAssertNil(entry(pages: .count(12)).issue(existing: [], now: now))
        XCTAssertNil(entry(minutes: 30, pages: .count(12)).issue(existing: [], now: now))
    }

    func testFutureAndImplausibleEntriesAreRefused() {
        XCTAssertEqual(entry(end: now.addingTimeInterval(600), minutes: 30).issue(existing: [], now: now), .inFuture)
        XCTAssertEqual(entry(end: now.addingTimeInterval(600), pages: .count(3)).issue(existing: [], now: now), .inFuture)
        XCTAssertEqual(entry(minutes: 25 * 60).issue(existing: [], now: now), .durationTooLong)
        XCTAssertEqual(entry(pages: .count(0)).issue(existing: [], now: now), .pagesNotPositive)
        XCTAssertEqual(entry(pages: .range(from: 40, to: 30)).issue(existing: [], now: now), .pagesNotPositive)
        XCTAssertEqual(entry(pages: .count(10_001)).issue(existing: [], now: now), .pagesTooMany(limit: 10_000))
        XCTAssertEqual(entry(pages: .range(from: 300, to: 350), total: 320).issue(existing: [], now: now), .pageBeyondTotal(total: 320))
        XCTAssertNil(entry(pages: .range(from: 300, to: 320), total: 320).issue(existing: [], now: now))
    }

    func testOnlyTimeCanOverlapTime() {
        let existing = ReadingInterval(id: "a", sessionID: "s", bookID: "other", start: now.addingTimeInterval(-7_200),
                                       end: now.addingTimeInterval(-5_400), duration: 1_800, timezoneID: zone, mode: .automatic)
        guard case .overlaps? = entry(end: now.addingTimeInterval(-5_000), minutes: 30).issue(existing: [existing], now: now) else {
            return XCTFail("overlap was not reported")
        }
        XCTAssertNil(entry(end: now.addingTimeInterval(-3_600), minutes: 30).issue(existing: [existing], now: now))
        XCTAssertNil(entry(end: now.addingTimeInterval(-5_000), pages: .count(5)).issue(existing: [existing], now: now))
    }

    func testRecordsCarryTimePagesAndPosition() {
        let records = entry(minutes: 30, pages: .range(from: 10, to: 30), total: 300).records(now: now)
        XCTAssertEqual(records.interval.mode, .manual)
        XCTAssertEqual(records.interval.duration, 1_800)
        XCTAssertEqual(records.interval.end.timeIntervalSince(records.interval.start), 1_800)
        let adjustment = records.events.first { $0.kind == "manualPageAdjustment" }?.pageAdjustment
        XCTAssertEqual(adjustment?.pages, 20)
        XCTAssertEqual(adjustment?.fromPage, 10)
        XCTAssertEqual(adjustment?.toPage, 30)
        XCTAssertEqual(records.progress?.page, 30)
        XCTAssertEqual(records.progress?.totalPages, 300)
    }

    func testPagesOnlyUsesAZeroCreditMarker() {
        let records = entry(pages: .count(7)).records(now: now)
        XCTAssertEqual(records.interval.duration, 0)
        XCTAssertEqual(records.interval.end.timeIntervalSince(records.interval.start), 1)
        XCTAssertFalse(records.events.contains { $0.kind == "manualAddition" })
        XCTAssertNil(records.progress)
    }

    func testParsers() {
        XCTAssertEqual(ManualEntryParsing.duration("45"), 2_700)
        XCTAssertEqual(ManualEntryParsing.duration("1h 20m"), 4_800)
        XCTAssertEqual(ManualEntryParsing.duration("1h20"), 4_800)
        XCTAssertEqual(ManualEntryParsing.duration("1:30"), 5_400)
        XCTAssertEqual(ManualEntryParsing.duration("1.5h"), 5_400)
        XCTAssertNil(ManualEntryParsing.duration("0"))
        XCTAssertNil(ManualEntryParsing.duration("soon"))
        XCTAssertEqual(ManualEntryParsing.clock("7:42 pm"), ManualEntryParsing.Clock(hour: 19, minute: 42))
        XCTAssertEqual(ManualEntryParsing.clock("12 am"), ManualEntryParsing.Clock(hour: 0, minute: 0))
        XCTAssertEqual(ManualEntryParsing.clock("742p"), ManualEntryParsing.Clock(hour: 19, minute: 42))
        XCTAssertEqual(ManualEntryParsing.clock("19:42"), ManualEntryParsing.Clock(hour: 19, minute: 42))
        XCTAssertNil(ManualEntryParsing.clock("25:00"))
    }

    func testLibraryMatcherRanksTitlePrefixFirst() {
        let books = [BookRecord(id: "1", title: "The Left Hand of Darkness", author: "Ursula K. Le Guin"),
                     BookRecord(id: "2", title: "Darkness at Noon", author: "Arthur Koestler"),
                     BookRecord(id: "3", title: "Dune", author: "Frank Herbert", format: .audiobook)]
        XCTAssertEqual(LibraryBookMatcher.matches(query: "dark", in: books).map(\.id), ["2", "1"])
        XCTAssertEqual(LibraryBookMatcher.matches(query: "le guin", in: books).map(\.id), ["1"])
        XCTAssertTrue(LibraryBookMatcher.matches(query: "dune", in: books, formats: [.text]).isEmpty)
        XCTAssertTrue(LibraryBookMatcher.matches(query: " ", in: books).isEmpty)
    }

    func testStoreCountsManualPagesTowardsPageGoalsWithoutCreditingTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
        let book = BookRecord(id: "openlibrary:OL1W", title: "Piranesi", source: "Open Library", pageCount: 272)
        var pagesOnly = entry(minutes: 0, pages: .count(20)); pagesOnly.bookID = book.id
        try store.saveManualEntry(book: book, records: pagesOnly.records(now: now))
        let archive = try store.archive()
        let intervals = try store.effectiveIntervals()
        let day = ReadingStatistics.dayKey(pagesOnly.end, timezoneID: zone)
        let goal = [GoalChange(effectiveDay: "2000-01-01", minutes: 20, pages: 20, primaryUnit: .pages)]
        let pages = PageStatistics.daily(events: archive.events, effectiveIntervals: intervals, goals: goal, merges: [],
                                         timezoneID: zone, from: now.addingTimeInterval(-86_400), through: now)
        XCTAssertEqual(pages.first { $0.day == day }?.pages, 20)
        XCTAssertEqual(pages.first { $0.day == day }?.qualifies, true)
        let time = ReadingStatistics.daily(intervals: intervals, goals: [], timezoneID: zone,
                                           from: now.addingTimeInterval(-86_400), through: now)
        XCTAssertEqual(time.first { $0.day == day }?.creditedSeconds, 0)
        XCTAssertEqual(PageStatistics.manualPages(events: archive.events, effectiveIntervals: intervals, merges: [], bookID: book.id), 20)
        XCTAssertEqual(archive.books.first?.pageCount, 272)
    }

    func testStoreRefusesInconsistentRangesAndLeavesNothingBehind() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
        let book = BookRecord(id: "b", title: "Book")
        var records = entry(minutes: 10, pages: .count(5)).records(now: now)
        records.events = records.events.map { event in
            var copy = event
            copy.pageAdjustment = event.pageAdjustment.map {
                ManualPageAdjustmentEvidence(pages: 5, recordedAt: $0.recordedAt, reason: $0.reason, fromPage: 10, toPage: 30)
            }
            return copy
        }
        XCTAssertThrowsError(try store.saveManualEntry(book: book, records: records))
        let archive = try store.archive()
        XCTAssertTrue(archive.books.isEmpty)
        XCTAssertTrue(archive.intervals.isEmpty)
    }

    func testOlderRecordsDecodeWithoutNewFields() throws {
        let book = try JSONDecoder().decode(BookRecord.self, from: Data(#"{"id":"x","title":"Old","source":"manual","observedAt":0,"trackingExcluded":false,"sharingExcluded":false}"#.utf8))
        XCTAssertNil(book.pageCount)
        let evidence = try JSONDecoder().decode(ManualPageAdjustmentEvidence.self, from: Data(#"{"pages":3,"recordedAt":0,"reason":"x"}"#.utf8))
        XCTAssertNil(evidence.fromPage)
    }
}

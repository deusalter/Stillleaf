import XCTest
@testable import BooksCore

final class ReadingCompletionDatesTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testOptionalDatesRangeAndOrder() {
        XCTAssertNil(ReadingCompletionDates(finishedAt: now).validationMessage(now: now))
        XCTAssertNil(ReadingCompletionDates(startedAt: now, finishedAt: nil).validationMessage(now: now))
        XCTAssertNil(ReadingCompletionDates(finishedAt: nil).validationMessage(now: now))
        XCTAssertNotNil(ReadingCompletionDates(startedAt: now, finishedAt: now.addingTimeInterval(-1)).validationMessage(now: now))
        XCTAssertNotNil(ReadingCompletionDates(finishedAt: now.addingTimeInterval(1)).validationMessage(now: now))
        XCTAssertNotNil(ReadingCompletionDates(finishedAt: .init(timeIntervalSince1970: .nan)).validationMessage(now: now))
        XCTAssertNotNil(ReadingCompletionDates(finishedAt: ReadingCompletionDates.earliestDate.addingTimeInterval(-1)).validationMessage(now: now))
    }

    func testSelectionPreservesExactInstantAndWallTimeAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let original = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 16, minute: 35, second: 17)))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: original))
        let selected = ReadingCompletionDates.selecting(day: nextDay, preserving: original, calendar: calendar, now: now)
        XCTAssertEqual(calendar.component(.hour, from: selected), 16)
        XCTAssertEqual(selected.timeIntervalSince(original), 23 * 3600)
        let fractional = original.addingTimeInterval(0.12345)
        XCTAssertEqual(ReadingCompletionDates.selecting(day: original, preserving: fractional, calendar: calendar, now: now), fractional)
    }

    func testOldCompletionPayloadDecodesUnknownStart() throws {
        let data = Data(#"{"finishedAt":12345,"source":"You","imported":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(BookCompletionEvidence.self, from: data).startedAt)
    }

    func testDatesPersistExportAndRejectInvalidEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
        let book = BookRecord(id: "synthetic", title: "Synthetic")
        try store.saveBook(book)
        let start = now.addingTimeInterval(-86400)
        let evidence = BookCompletionEvidence(startedAt: start, finishedAt: now, source: "You", imported: false)
        try store.appendEvent(AuditEvent(date: now, kind: "bookCompleted", bookID: book.id, detail: "test", completion: evidence))
        let bad = BookCompletionEvidence(startedAt: now.addingTimeInterval(1), finishedAt: now, source: "You", imported: false)
        XCTAssertThrowsError(try store.appendEvent(AuditEvent(date: now, kind: "bookCompleted", bookID: book.id, detail: "test", completion: bad)))
        let events = try store.archive().events
        XCTAssertEqual(events.filter { $0.kind == "bookCompleted" }.count, 1)
        XCTAssertEqual(BookHistory.completedBooks(books: [book], events: events).first?.startedAt, start)
        let export = directory.appendingPathComponent("backup.json")
        try store.exportJSON(to: export)
        let restored = try ReadingStore(url: directory.appendingPathComponent("restored.sqlite"))
        try restored.importJSON(from: export)
        XCTAssertEqual(try restored.archive().events.first(where: { $0.kind == "bookCompleted" })?.completion, evidence)
        let csv = directory.appendingPathComponent("csv")
        try store.exportCSV(to: csv)
        let text = try String(contentsOf: csv.appendingPathComponent("events.csv"))
        XCTAssertTrue(text.components(separatedBy: "\n")[0].hasSuffix(",started_at"))
        XCTAssertFalse(try XCTUnwrap(text.components(separatedBy: "\n").first(where: { $0.contains(",bookCompleted,") })).hasSuffix(","))
    }
}

import XCTest
@testable import BooksCore

final class BookHistoryTests: XCTestCase {
    func testManualCompletionOverridesCatalogAndUnknownDatesSortLast() {
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        let books = [
            BookRecord(id: "a", title: "Alpha", author: "Author A"),
            BookRecord(id: "b", title: "Beta"),
            BookRecord(id: "unfinished", title: "Unfinished")
        ]
        let importedDate = observed.addingTimeInterval(-10_000)
        let manualDate = observed.addingTimeInterval(-20_000)
        let events = [
            completion(id: "import-a", bookID: "a", observedAt: observed, finishedAt: importedDate, source: "Apple Books catalog", imported: true),
            completion(id: "manual-a", bookID: "a", observedAt: observed.addingTimeInterval(1), finishedAt: manualDate, source: "User edit", imported: false),
            completion(id: "repeat-a", bookID: "a", observedAt: observed.addingTimeInterval(2), finishedAt: importedDate.addingTimeInterval(50), source: "Apple Books catalog", imported: true),
            completion(id: "import-b", bookID: "b", observedAt: observed.addingTimeInterval(3), finishedAt: nil, source: "Apple Books catalog", imported: true),
            completion(id: "deleted", bookID: "missing", observedAt: observed.addingTimeInterval(4), finishedAt: observed, source: "ignored", imported: true)
        ]
        let entries = BookHistory.completedBooks(books: books, events: events)
        XCTAssertEqual(entries.map(\.id), ["a", "b"])
        XCTAssertEqual(entries[0].finishedAt, manualDate)
        XCTAssertEqual(entries[0].source, "User edit")
        XCTAssertFalse(entries[0].imported)
        XCTAssertNil(entries[1].finishedAt)
        XCTAssertTrue(entries[1].imported)
    }

    func testLatestRatingAndExplicitClearWin() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var events = [
            rating(id: "first", bookID: "book", observedAt: date, value: 4.25),
            rating(id: "other", bookID: "other", observedAt: date.addingTimeInterval(1), value: 5),
            rating(id: "clear", bookID: "book", observedAt: date.addingTimeInterval(2), value: nil)
        ]
        XCTAssertNil(BookHistory.rating(bookID: "book", events: events))
        events.append(rating(id: "latest", bookID: "book", observedAt: date.addingTimeInterval(2), value: 3.75))
        XCTAssertEqual(BookHistory.rating(bookID: "book", events: events), 3.75)
    }

    func testStoreValidatesPersistsExportsAndDeletesBookHistoryEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
        let book = BookRecord(id: "book", title: "Synthetic")
        try store.saveBook(book)
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        let finished = observed.addingTimeInterval(-86_400)
        let completionEvent = completion(id: "completion", bookID: book.id, observedAt: observed, finishedAt: finished,
                                         source: "Apple Books catalog", imported: true)
        let ratingEvent = rating(id: "rating", bookID: book.id, observedAt: observed.addingTimeInterval(1), value: 4.25)
        let clearEvent = rating(id: "rating-clear", bookID: book.id, observedAt: observed.addingTimeInterval(2), value: nil)
        try store.appendEvent(completionEvent)
        try store.appendEvent(ratingEvent)
        try store.appendEvent(clearEvent)
        try store.appendEvent(completionEvent)
        XCTAssertEqual(try store.archive().events.filter { $0.id == completionEvent.id }.count, 1)
        XCTAssertEqual(BookHistory.completedBooks(books: [book], events: try store.archive().events).first?.finishedAt, finished)
        XCTAssertNil(BookHistory.rating(bookID: book.id, events: try store.archive().events))

        for value in [-0.25, 4.1, 5.25, .infinity, .nan] {
            XCTAssertThrowsError(try store.appendEvent(rating(id: UUID().uuidString, bookID: book.id,
                observedAt: observed.addingTimeInterval(3), value: value)))
        }
        XCTAssertThrowsError(try store.appendEvent(AuditEvent(kind: "bookRated", bookID: book.id, detail: "missing")))
        XCTAssertThrowsError(try store.appendEvent(AuditEvent(kind: "bookCompleted", bookID: book.id, detail: "bad",
            completion: BookCompletionEvidence(finishedAt: finished, source: "Page\nTitle", imported: true))))
        XCTAssertThrowsError(try store.appendEvent(AuditEvent(date: observed, kind: "bookCompleted", bookID: book.id,
            detail: "future", completion: BookCompletionEvidence(finishedAt: observed.addingTimeInterval(1),
                source: "User edit", imported: false))))
        XCTAssertThrowsError(try store.appendEvent(AuditEvent(kind: "bookCompleted", bookID: book.id, detail: "multiple",
            completion: BookCompletionEvidence(finishedAt: finished, source: "User edit", imported: false),
            rating: BookRatingEvidence(value: 4))))

        let export = directory.appendingPathComponent("history.json")
        try store.exportJSON(to: export)
        let imported = try ReadingStore(url: directory.appendingPathComponent("imported.sqlite"))
        try imported.importJSON(from: export)
        XCTAssertEqual(try imported.archive().events.first(where: { $0.id == completionEvent.id })?.completion,
                       completionEvent.completion)
        XCTAssertNil(BookHistory.rating(bookID: book.id, events: try imported.archive().events))

        let csv = directory.appendingPathComponent("csv")
        try store.exportCSV(to: csv)
        let eventsCSV = try String(contentsOf: csv.appendingPathComponent("events.csv"))
        XCTAssertTrue(eventsCSV.contains("finished_at,completion_source,completion_imported,rating_state,rating_value"))
        XCTAssertTrue(eventsCSV.contains("Apple Books catalog,true"))
        XCTAssertTrue(eventsCSV.contains("clear,"))

        try store.deleteBook(book.id)
        XCTAssertFalse(try store.archive().events.contains { $0.completion != nil || $0.rating != nil })
    }

    func testLegacyAuditEventDecodesWithoutNewTypedFields() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let event = try decoder.decode(AuditEvent.self,
            from: Data(#"{"id":"legacy","date":1700000000000,"kind":"legacy","detail":"old"}"#.utf8))
        XCTAssertNil(event.completion)
        XCTAssertNil(event.rating)
    }

    private func completion(id: String, bookID: String, observedAt: Date, finishedAt: Date?, source: String,
                            imported: Bool) -> AuditEvent {
        AuditEvent(id: id, date: observedAt, kind: "bookCompleted", bookID: bookID,
                   detail: imported ? "Imported completion metadata." : "User-edited completion metadata.",
                   completion: BookCompletionEvidence(finishedAt: finishedAt, source: source, imported: imported))
    }

    private func rating(id: String, bookID: String, observedAt: Date, value: Double?) -> AuditEvent {
        AuditEvent(id: id, date: observedAt, kind: "bookRated", bookID: bookID,
                   detail: value == nil ? "User cleared rating." : "User rated book.",
                   rating: BookRatingEvidence(value: value))
    }
}

import XCTest
@testable import BooksCore

final class ManualPageAdjustmentStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testAdjustmentPersistsRoundTripsExportsAndDeletesWithSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
        let book = BookRecord(id: "book", title: "Synthetic")
        try store.saveBook(book)
        let interval = automaticInterval(bookID: book.id)
        try store.appendInterval(interval)
        let adjustment = ManualPageAdjustmentEvidence(pages: 123,
            recordedAt: interval.end.addingTimeInterval(3_600), reason: "Correct last night's total")
        let event = AuditEvent(id: "adjustment", date: interval.end, kind: "manualPageAdjustment",
                               bookID: book.id, sessionID: interval.sessionID,
                               detail: "User added 123 pages to this session.", pageAdjustment: adjustment)
        try store.appendEvent(event)
        try store.appendEvent(event)
        XCTAssertEqual(try store.archive().events.filter { $0.id == event.id }.count, 1)
        XCTAssertEqual(try store.archive().events.first(where: { $0.id == event.id })?.pageAdjustment, adjustment)

        let export = directory.appendingPathComponent("history.json")
        try store.exportJSON(to: export)
        let imported = try ReadingStore(url: directory.appendingPathComponent("imported.sqlite"))
        try imported.importJSON(from: export)
        XCTAssertEqual(try imported.archive().events.first(where: { $0.id == event.id })?.pageAdjustment, adjustment)

        let csv = directory.appendingPathComponent("csv")
        try store.exportCSV(to: csv)
        let eventsCSV = try String(contentsOf: csv.appendingPathComponent("events.csv"))
        XCTAssertTrue(eventsCSV.contains("adjustment_pages,adjustment_recorded_at,adjustment_reason"))
        XCTAssertTrue(eventsCSV.contains("123"))
        XCTAssertTrue(eventsCSV.contains("Correct last night's total"))

        try imported.deleteBook(book.id)
        XCTAssertFalse(try imported.archive().events.contains { $0.pageAdjustment != nil })

        try store.deleteSession(interval.sessionID)
        XCTAssertFalse(try store.archive().events.contains { $0.pageAdjustment != nil })
    }

    func testAdjustmentRequiresValidEvidenceAndMatchingAutomaticInterval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
        let book = BookRecord(id: "book", title: "Synthetic")
        try store.saveBook(book)
        let interval = automaticInterval(bookID: book.id)
        try store.appendInterval(interval)
        let valid = ManualPageAdjustmentEvidence(pages: 1, recordedAt: interval.end, reason: "Manual correction")

        func event(id: String = UUID().uuidString, date: Date? = nil, kind: String = "manualPageAdjustment",
                   bookID: String? = "book", sessionID: String? = "session",
                   evidence: ManualPageAdjustmentEvidence? = nil, includeEvidence: Bool = true) -> AuditEvent {
            AuditEvent(id: id, date: date ?? interval.end, kind: kind, bookID: bookID, sessionID: sessionID,
                       detail: "Manual page adjustment.", pageAdjustment: includeEvidence ? (evidence ?? valid) : nil)
        }

        XCTAssertNoThrow(try store.appendEvent(event(id: "within-tolerance",
            date: interval.end.addingTimeInterval(0.0005),
            evidence: ManualPageAdjustmentEvidence(pages: 1,
                recordedAt: interval.end.addingTimeInterval(1), reason: "Manual correction"))))
        for pages in [0, -1, 1_000_001] {
            XCTAssertThrowsError(try store.appendEvent(event(evidence:
                ManualPageAdjustmentEvidence(pages: pages, recordedAt: interval.end, reason: "Manual correction"))))
        }
        XCTAssertThrowsError(try store.appendEvent(event(evidence:
            ManualPageAdjustmentEvidence(pages: 1, recordedAt: interval.end.addingTimeInterval(-1), reason: "Manual correction"))))
        for reason in ["", "   ", String(repeating: "a", count: 513), "line\nbreak"] {
            XCTAssertThrowsError(try store.appendEvent(event(evidence:
                ManualPageAdjustmentEvidence(pages: 1, recordedAt: interval.end, reason: reason))))
        }
        XCTAssertThrowsError(try store.appendEvent(event(kind: "pageTurn")))
        XCTAssertThrowsError(try store.appendEvent(event(bookID: nil)))
        XCTAssertThrowsError(try store.appendEvent(event(bookID: "missing")))
        XCTAssertThrowsError(try store.appendEvent(event(sessionID: nil)))
        XCTAssertThrowsError(try store.appendEvent(event(sessionID: "missing")))
        XCTAssertThrowsError(try store.appendEvent(event(date: interval.end.addingTimeInterval(0.002),
            evidence: ManualPageAdjustmentEvidence(pages: 1,
                recordedAt: interval.end.addingTimeInterval(1), reason: "Manual correction"))))
        XCTAssertThrowsError(try store.appendEvent(event(includeEvidence: false)))
        XCTAssertThrowsError(try store.appendEvent(AuditEvent(date: interval.end, kind: "manualPageAdjustment",
            bookID: book.id, sessionID: interval.sessionID, detail: "multiple",
            pageTurn: PageTurnEvidence(fromPage: 1, toPage: 2, pagesRead: 1,
                                       visiblePages: 1, layoutSignature: "layout"),
            pageAdjustment: valid)))

        let manual = ReadingInterval(id: "manual", sessionID: "manual", bookID: book.id,
            start: start.addingTimeInterval(20), end: start.addingTimeInterval(30), duration: 10,
            timezoneID: "UTC", mode: .manual)
        try store.appendInterval(manual)
        XCTAssertThrowsError(try store.appendEvent(event(date: manual.end, sessionID: manual.sessionID,
            evidence: ManualPageAdjustmentEvidence(pages: 1,
                recordedAt: manual.end, reason: "Manual correction"))))
    }

    func testInvalidImportedAdjustmentIsRejectedAtomicallyAndLegacyEventDecodes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
        try store.saveBook(BookRecord(id: "kept", title: "Kept"))
        let before = try store.archive()

        var archive = HistoryArchive()
        archive.books = [BookRecord(id: "book", title: "Synthetic")]
        let interval = automaticInterval(bookID: "book")
        archive.intervals = [interval]
        archive.events = [AuditEvent(id: "invalid", date: interval.end, kind: "manualPageAdjustment",
            bookID: "book", sessionID: interval.sessionID, detail: "invalid",
            pageAdjustment: ManualPageAdjustmentEvidence(pages: 1_000_001,
                recordedAt: interval.end, reason: "Manual correction"))]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let importURL = directory.appendingPathComponent("invalid.json")
        try encoder.encode(archive).write(to: importURL)
        XCTAssertThrowsError(try store.importJSON(from: importURL))
        var after = try store.archive()
        after.exportedAt = before.exportedAt
        XCTAssertEqual(after, before)

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let legacy = try decoder.decode(AuditEvent.self,
            from: Data(#"{"id":"legacy","date":1700000000000,"kind":"legacy","detail":"old"}"#.utf8))
        XCTAssertNil(legacy.pageAdjustment)
    }

    private func automaticInterval(bookID: String) -> ReadingInterval {
        ReadingInterval(id: "interval", sessionID: "session", bookID: bookID,
                        start: start, end: start.addingTimeInterval(10), duration: 10,
                        timezoneID: "UTC", mode: .automatic)
    }
}

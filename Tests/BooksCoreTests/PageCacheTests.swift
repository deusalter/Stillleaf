import XCTest
@testable import BooksCore

final class PageCacheTests: XCTestCase {
    func testLiveIntervalCacheUsesDurableDateRepresentationAtPageBoundary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
        let book = BookRecord(id: "book", title: "Synthetic")
        try store.saveBook(book)
        _ = try store.effectiveIntervals()

        let boundary = Date(timeIntervalSince1970: Double(bitPattern: 4_745_293_591_915_450_005))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let decodedBoundary = try decoder.decode(Date.self, from: encoder.encode(boundary))
        XCTAssertGreaterThan(decodedBoundary, boundary)

        let interval = ReadingInterval(id: "interval", sessionID: "session", bookID: book.id,
            start: boundary.addingTimeInterval(-1), end: boundary, duration: 1,
            timezoneID: "UTC", mode: .automatic)
        try store.appendCheckpoint(interval: interval,
            event: AuditEvent(date: boundary, kind: "trackingCheckpoint", bookID: book.id,
                              sessionID: interval.sessionID, detail: "Synthetic checkpoint"))
        try store.appendEvent(AuditEvent(date: boundary, kind: "pageTurn", bookID: book.id,
            sessionID: interval.sessionID, detail: "Synthetic page boundary",
            pageTurn: PageTurnEvidence(fromPage: 1, toPage: 2, pagesRead: 1,
                                       visiblePages: 1, layoutSignature: "layout")))

        let archive = try store.archive()
        let cached = try store.effectiveIntervals()
        XCTAssertEqual(cached.first?.end, archive.intervals.first?.end)
        XCTAssertEqual(PageStatistics.pages(events: archive.events, effectiveIntervals: cached, merges: []), 1)
    }
}

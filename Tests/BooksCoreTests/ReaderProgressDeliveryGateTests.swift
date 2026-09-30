import XCTest
@testable import BooksCore

final class ReaderProgressDeliveryGateTests: XCTestCase {
    func testFinalPositionPersistsOnceWithoutCreatingActivity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingStore(url: root.appendingPathComponent("history.sqlite"))
        let book = BookRecord(id: "epub:test", title: "Synthetic")
        try store.saveBook(book)
        let engine = try TrackingEngine(store: store, timezoneID: "UTC")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ProgressObservation(bookID: book.id, observedAt: date, fraction: 0.1,
                                        location: "Chapter 1", source: "stillleaf-epub-location", reliable: true)
        try engine.process(TrackingInput(date: date, uptime: 100, book: book, progress: first))
        try engine.process(TrackingInput(date: date.addingTimeInterval(1), uptime: 101, pauseReason: .background))
        let seconds = engine.snapshot.sessionSeconds
        let before = try store.archive()
        var final = first
        final.id = UUID().uuidString; final.fraction = 0.12
        try engine.recordPosition(final)
        var duplicate = final
        duplicate.id = UUID().uuidString; duplicate.observedAt = date.addingTimeInterval(2)
        try engine.recordPosition(duplicate)
        let after = try store.archive()
        XCTAssertEqual(after.progress.count, before.progress.count + 1)
        XCTAssertEqual(after.progress.last?.fraction, 0.12)
        XCTAssertEqual(after.intervals, before.intervals)
        XCTAssertEqual(after.events, before.events)
        XCTAssertEqual(engine.snapshot.phase, .paused)
        XCTAssertEqual(engine.snapshot.sessionSeconds, seconds)
    }

    func testContinuousBurstHasLeadingAndBoundedTrailingDeliveries() {
        var gate = ReaderProgressDeliveryGate()
        var deliveries = 0
        var latest = 0
        var delivered = -1
        for tick in 0..<600 {
            latest = tick
            let now = Double(tick) / 60
            if gate.request(at: now) == 0, gate.deliver(at: now) {
                deliveries += 1
                delivered = latest
            }
        }
        XCTAssertEqual(deliveries, 10, "Ten seconds of 60Hz input must not cause 600 tracking updates")
        XCTAssertEqual(delivered, 540)
        XCTAssertTrue(gate.pending)
        XCTAssertTrue(gate.deliver(at: 10))
        delivered = latest
        XCTAssertEqual(delivered, 599, "Trailing delivery must read the host's newest position")
    }

    func testNewRequestsDoNotStarveTheTrailingDeadline() {
        var gate = ReaderProgressDeliveryGate()
        XCTAssertEqual(gate.request(at: 100), 0)
        gate.deliver(at: 100)
        XCTAssertEqual(gate.request(at: 100.2), 0.8, accuracy: 0.0001)
        XCTAssertEqual(gate.request(at: 100.9), 0.1, accuracy: 0.0001)
        XCTAssertEqual(gate.request(at: 101), 0)
    }

    func testCloseFlushDeliversPendingOnceWithoutWaiting() {
        var gate = ReaderProgressDeliveryGate()
        XCTAssertFalse(gate.deliver(at: 0))
        _ = gate.request(at: 1)
        XCTAssertTrue(gate.deliver(at: 1))
        XCTAssertGreaterThan(gate.request(at: 1.1), 0)
        XCTAssertTrue(gate.deliver(at: 1.1))
        XCTAssertFalse(gate.pending)
        XCTAssertFalse(gate.deliver(at: 2), "A cancelled trailing callback cannot duplicate the close flush")
    }
}

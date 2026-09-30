import Foundation
import XCTest
@testable import BooksCore

final class ReadingTrackingSourceTests: XCTestCase {
    func testPermissionWarningsRequireForegroundAppleBooks() {
        XCTAssertEqual(source(access: false), .idle)
        XCTAssertEqual(source(access: true), .idle)
        XCTAssertEqual(source(appleBooks: true, access: false), .appleBooksNeedsAccess)
        XCTAssertEqual(source(appleBooks: true, access: true), .appleBooks)
        // The native reader wins even if the external adapter reports foreground.
        for access in [false, true] {
            XCTAssertEqual(source(native: true, appleBooks: true, access: access), .nativeReader)
            XCTAssertEqual(source(manual: true, appleBooks: true, access: access), .manual)
        }
    }

    func testNativeReadingPersistsTimeCoveragePositionAndPresenceWithDeniedAccess() throws {
        // Exercise the same native source selection, engine, durable evidence and
        // presence policy used by AppModel, for both OS permission states.
        for access in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("history.sqlite")
            let store = try ReadingStore(url: url)
            let engine = try TrackingEngine(store: store, timezoneID: "UTC")
            let book = BookRecord(id: "epub:fixture", title: "Native fixture", source: "stillleaf-epub")
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            var presence = ReadingPresencePolicy()
            for second in 0...4 {
                let route = source(native: true, access: access)
                XCTAssertEqual(route, .nativeReader)
                let position = try nativePosition(page: second < 2 ? 1 : 2)
                let progress = try XCTUnwrap(position.observation(bookID: book.id, spine: ["one.xhtml"],
                    date: start.addingTimeInterval(Double(second))))
                try engine.process(TrackingInput(date: progress.observedAt, uptime: Double(100 + second),
                    book: book, mode: .automatic, relevantActivity: true, progress: progress))
                presence.observe(bookID: book.id, navigationToken: nil, relevantActivity: true,
                    uptime: Double(100 + second))
                XCTAssertEqual(engine.snapshot.phase, .reading)
                XCTAssertNil(engine.snapshot.pauseReason)
                XCTAssertEqual(presence.state(for: engine.snapshot, book: book, enabled: true,
                    readerOpen: route == .nativeReader, uptime: Double(100 + second)), .reading)
                if second == 1 || second == 3 {
                    try store.appendEvent(AuditEvent(date: progress.observedAt, kind: "pageTurn", bookID: book.id,
                        sessionID: engine.snapshot.sessionID, detail: "Native sequential content traversal",
                        pageTurn: try XCTUnwrap(position.forwardCoverage(spine: ["one.xhtml"]))))
                }
            }
            try engine.stop(date: start.addingTimeInterval(4), uptime: 104)
            // A final background position is saved without crediting background time.
            let final = try XCTUnwrap(nativePosition(page: 3).observation(bookID: book.id, spine: ["one.xhtml"],
                date: start.addingTimeInterval(5)))
            try engine.recordPosition(final)
            let reopened = try ReadingStore(url: url)
            let archive = try reopened.archive()
            let intervals = try reopened.effectiveIntervals()
            XCTAssertEqual(intervals.filter { $0.disposition == .credited }.reduce(0) { $0 + $1.duration }, 4, accuracy: 0.001)
            XCTAssertTrue(intervals.allSatisfy { $0.mode == .automatic })
            XCTAssertEqual(PageStatistics.pages(events: archive.events, effectiveIntervals: intervals, merges: []), 2)
            XCTAssertEqual(archive.progress.last?.location, "Chapter 1 of 1 · Page 3 of 10")
            XCTAssertEqual(archive.progress.last?.fraction, 0.3)
            XCTAssertFalse(archive.events.contains { $0.detail == PauseReason.permissionLost.rawValue })
            XCTAssertEqual(presence.state(for: engine.snapshot, book: book, enabled: true,
                readerOpen: false, uptime: 105), .hidden)
        }
    }

    func testAppleBooksDeniedAccessPausesTimeAndPresenceThenCanResume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingStore(url: root.appendingPathComponent("history.sqlite"))
        let engine = try TrackingEngine(store: store, timezoneID: "UTC")
        let book = BookRecord(id: "apple-fixture", title: "Apple Books fixture")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(source(appleBooks: true, access: false), .appleBooksNeedsAccess)
        try engine.process(TrackingInput(date: start, uptime: 100, book: book, pauseReason: .permissionLost))
        XCTAssertEqual(engine.snapshot.pauseReason, .permissionLost)
        XCTAssertTrue(try store.effectiveIntervals().isEmpty)
        var presence = ReadingPresencePolicy()
        presence.observe(bookID: book.id, navigationToken: "1", relevantActivity: true, uptime: 100)
        XCTAssertEqual(presence.state(for: engine.snapshot, book: book, enabled: true, readerOpen: true, uptime: 100), .hidden)
        XCTAssertEqual(source(appleBooks: true, access: true), .appleBooks)
        try engine.process(TrackingInput(date: start.addingTimeInterval(1), uptime: 101, book: book, relevantActivity: true))
        XCTAssertEqual(engine.snapshot.phase, .reading)
        XCTAssertNil(engine.snapshot.pauseReason)
    }

    private func source(manual: Bool = false, native: Bool = false, appleBooks: Bool = false, access: Bool) -> ReadingTrackingSource {
        ReadingTrackingSource.resolve(manualReading: manual, nativeReaderFocused: native,
            appleBooksForeground: appleBooks, accessibilityGranted: access)
    }

    private func nativePosition(page: Int) throws -> NativeReaderPosition {
        let lower = (page - 1) * 200
        let data = Data("{\"href\":\"one.xhtml\",\"page\":\(page),\"totalPages\":10,\"visiblePages\":1,\"bookOffset\":\(page * 200),\"bookTotal\":2000,\"lower\":\(lower),\"upper\":\(lower + 200)}".utf8)
        return try JSONDecoder().decode(NativeReaderPosition.self, from: data)
    }
}

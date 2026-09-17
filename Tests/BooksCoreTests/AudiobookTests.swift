import XCTest
@testable import BooksCore

final class AudiobookTests: XCTestCase {
    func testLegacyRecordsDecodeWithoutAudioMetadata() throws {
        let book = try JSONDecoder().decode(BookRecord.self, from: Data(#"{"id":"old","title":"Old book","source":"manual","observedAt":0,"trackingExcluded":false,"sharingExcluded":false}"#.utf8))
        XCTAssertEqual(book.resolvedFormat, .text)
        XCTAssertNil(book.audioFileName)
        let progress = try JSONDecoder().decode(ProgressObservation.self, from: Data(#"{"id":"p","bookID":"old","observedAt":0,"page":12,"source":"manual","reliable":true}"#.utf8))
        XCTAssertNil(progress.audio)
        XCTAssertEqual(progress.page, 12)
    }

    func testContentPositionValidationAndFormatting() {
        let audio = AudiobookProgress(positionSeconds: 8100, durationSeconds: 36000)
        XCTAssertEqual(audio.fraction, 0.225)
        XCTAssertEqual(audio.description, "2:15:00 / 10:00:00")
        XCTAssertEqual(AudiobookProgress.parse("2:15"), 8100)
        XCTAssertEqual(AudiobookProgress.parse("135"), 8100)
        XCTAssertEqual(AudiobookProgress.parse("2:15:30"), 8130)
        XCTAssertNil(AudiobookProgress.parse("2:75"))
        XCTAssertNil(AudiobookProgress.parse("-1"))
        XCTAssertFalse(AudiobookProgress(positionSeconds: 5, durationSeconds: 0).isValid)
        XCTAssertFalse(AudiobookProgress(positionSeconds: 11, durationSeconds: 10).isValid)
        XCTAssertFalse(AudiobookProgress(positionSeconds: .nan, durationSeconds: 10).isValid)
    }

    func testListeningClockDoesNotCreditSleepOrClockJumps() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = ListeningClock()
        clock.start(date: date, uptime: 100)
        XCTAssertEqual(clock.checkpoint(date: date.addingTimeInterval(5), uptime: 105)?.seconds, 5)
        XCTAssertNil(clock.checkpoint(date: date.addingTimeInterval(65), uptime: 165))
        XCTAssertEqual(clock.checkpoint(date: date.addingTimeInterval(70), uptime: 170)?.seconds, 5)
        XCTAssertNil(clock.checkpoint(date: date.addingTimeInterval(5), uptime: 175))
    }

    func testTransactionalPositionAndTimeRoundTripAndRollback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingStore(url: root.appendingPathComponent("history.sqlite"))
        let book = BookRecord(id: "audio", title: "Audio", format: .audiobook)
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        let audio = AudiobookProgress(positionSeconds: 3600, durationSeconds: 36000)
        let progress = ProgressObservation(bookID: book.id, observedAt: end, fraction: audio.fraction,
            source: "manual-audio", reliable: true, audio: audio, sessionID: "session")
        let interval = ReadingInterval(sessionID: "session", bookID: book.id, start: end.addingTimeInterval(-1800),
            end: end, duration: 1800, timezoneID: "UTC", mode: .manual)
        try store.saveAudiobook(book, progress: progress, interval: interval)
        XCTAssertEqual(try store.effectiveIntervals().map(\.duration), [1800])
        // Changing content position without a session cannot add time or pages.
        let rewind = AudiobookProgress(positionSeconds: 1200, durationSeconds: 36000)
        try store.saveAudiobook(book, progress: ProgressObservation(bookID: book.id, source: "manual-audio", audio: rewind))
        XCTAssertEqual(try store.effectiveIntervals().count, 1)
        let before = try store.archive()
        var invalid = ProgressObservation(bookID: book.id, source: "manual-audio", audio: audio, sessionID: "second")
        invalid.page = 5
        let next = ReadingInterval(sessionID: "second", bookID: book.id, start: end, end: end.addingTimeInterval(10),
            duration: 10, timezoneID: "UTC", mode: .listening)
        XCTAssertThrowsError(try store.saveAudiobook(book, progress: invalid, interval: next))
        XCTAssertEqual(try store.archive().intervals, before.intervals)
        XCTAssertEqual(try store.effectiveIntervals().count, 1)
        let export = root.appendingPathComponent("export.json")
        try store.exportJSON(to: export)
        let imported = try ReadingStore(url: root.appendingPathComponent("imported.sqlite"))
        try imported.importJSON(from: export)
        XCTAssertEqual(try imported.archive().progress, before.progress)
        XCTAssertEqual(try imported.archive().books, before.books)
    }
}

import Foundation
import XCTest
import CSQLite
@testable import BooksCore

final class LegacyReadingHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testLegacyDispositionsDecodeButOnlyCurrentValuesEncode() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let legacy = Data(#""uncertain""#.utf8)
        XCTAssertEqual(try decoder.decode(IntervalDisposition.self, from: legacy), .credited)
        XCTAssertEqual(try decoder.decode(TrackerPhase.self, from: legacy), .reading)
        XCTAssertEqual(String(decoding: try encoder.encode(IntervalDisposition.credited), as: UTF8.self), #""credited""#)
        XCTAssertEqual(try decoder.decode(IntervalDisposition.self, from: Data(#""excluded""#.utf8)), .excluded)
        XCTAssertThrowsError(try decoder.decode(IntervalDisposition.self, from: Data(#""unknown""#.utf8)))
    }

    func testLegacyImportPreservesDurationsAndExcludedCorrectionsAndIsIdempotent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.json")
        try legacyData(fixture()).write(to: url)
        let store = try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
        try store.importJSON(from: url)
        try assertPreservedHistory(store)
        try store.importJSON(from: url)
        XCTAssertEqual(try store.archive().intervals.count, 3)
        XCTAssertEqual(try store.archive().corrections.count, 1)
        try assertPreservedHistory(store)
        let export = directory.appendingPathComponent("current.json")
        try store.exportJSON(to: export)
        XCTAssertFalse(try String(contentsOf: export).contains("uncertain"))
        let copy = try ReadingStore(url: directory.appendingPathComponent("copy.sqlite"))
        try copy.importJSON(from: export)
        XCTAssertEqual(try copy.effectiveIntervals(), try store.effectiveIntervals())
    }

    func testExistingSQLiteRowsAndCorrectionPayloadsDecodeWithoutMigrationOrDataLoss() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let archive = fixture()
        let export = directory.appendingPathComponent("fixture.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(archive).write(to: export)
        var store: ReadingStore? = try ReadingStore(url: databaseURL)
        try store!.importJSON(from: export)
        store = nil
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        // Reproduce old on-disk payloads, including nested correction replacements.
        // The indexed IDs and date columns are unchanged by the retired state.
        for interval in archive.intervals {
            let payload = try legacyData(interval).base64EncodedString()
            XCTAssertEqual(sqlite3_exec(database, "UPDATE intervals SET payload='\(payload)' WHERE id='\(interval.id)'", nil, nil, nil), SQLITE_OK)
        }
        for correction in archive.corrections {
            let payload = try legacyData(correction).base64EncodedString()
            XCTAssertEqual(sqlite3_exec(database, "UPDATE corrections SET payload='\(payload)' WHERE id='\(correction.id)'", nil, nil, nil), SQLITE_OK)
        }
        let reopened = try ReadingStore(url: databaseURL)
        try assertPreservedHistory(reopened)
        // Importing the same legacy records into a legacy database must compare
        // decoded values rather than reporting a false immutable-ID conflict.
        try legacyData(archive).write(to: export)
        try reopened.importJSON(from: export)
        try assertPreservedHistory(reopened)
    }

    private func assertPreservedHistory(_ store: ReadingStore) throws {
        let intervals = try store.effectiveIntervals()
        let expected = Array(fixture().intervals.dropFirst()) + fixture().corrections[0].replacements
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: intervals.map { ($0.id, $0) }),
                       Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) }))
        XCTAssertEqual(intervals.filter { $0.disposition == .credited }.reduce(0) { $0 + $1.duration }, 900)
        XCTAssertEqual(intervals.filter { $0.disposition == .excluded }.reduce(0) { $0 + $1.duration }, 900)
        let days = ReadingStatistics.daily(intervals: intervals, goals: [], timezoneID: "UTC", from: start, through: start)
        XCTAssertEqual(days.first?.creditedSeconds, 900)
        XCTAssertEqual(try store.archive().corrections.first?.originalIDs, ["original"])
    }

    private func fixture() -> HistoryArchive {
        func interval(_ id: String, offset: Double, duration: Double, disposition: IntervalDisposition = .credited) -> ReadingInterval {
            ReadingInterval(id: id, sessionID: "legacy-session", bookID: "book", start: start.addingTimeInterval(offset),
                end: start.addingTimeInterval(offset + duration), duration: duration, timezoneID: "UTC", mode: .automatic, disposition: disposition)
        }
        var archive = HistoryArchive()
        archive.books = [BookRecord(id: "book", title: "Legacy reading", observedAt: start)]
        archive.intervals = [interval("original", offset: 0, duration: 600), interval("later", offset: 600, duration: 600),
                            interval("excluded", offset: 1200, duration: 600, disposition: .excluded)]
        archive.corrections = [IntervalCorrection(id: "correction", originalIDs: ["original"], replacements: [
            interval("replacement", offset: 0, duration: 300),
            interval("excluded-replacement", offset: 300, duration: 300, disposition: .excluded)], reason: "Keep explicit exclusion")]
        return archive
    }

    private func legacyData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let json = String(decoding: try encoder.encode(value), as: UTF8.self)
        return Data(json.replacingOccurrences(of: #""credited""#, with: #""uncertain""#).utf8)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyReadingHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

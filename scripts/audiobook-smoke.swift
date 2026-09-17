import Foundation
import BooksCore

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ReadingStoreError.invalidData(message) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-smoke-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let store = try ReadingStore(url: root.appendingPathComponent("history.sqlite"))
let old = try JSONDecoder().decode(BookRecord.self, from: Data(#"{"id":"old","title":"Old","source":"manual","observedAt":0,"trackingExcluded":false,"sharingExcluded":false}"#.utf8))
try store.saveBook(old)
try require(old.resolvedFormat == .text, "legacy format")
let audio = AudiobookProgress(positionSeconds: 8100, durationSeconds: 36000)
try require(audio.description == "2:15:00 / 10:00:00" && audio.fraction == 0.225, "content formatting")
try require(AudiobookProgress.parse("2:15") == 8100 && AudiobookProgress.parse("2:60") == nil, "input parser")
let book = BookRecord(id: "audio", title: "Fixture", format: .audiobook)
let end = Date(timeIntervalSince1970: 1_700_000_000)
let interval = ReadingInterval(sessionID: "session", bookID: book.id, start: end.addingTimeInterval(-1800), end: end,
    duration: 1800, timezoneID: "UTC", mode: .listening, audioSessionID: "session")
let observation = ProgressObservation(bookID: book.id, observedAt: end, fraction: audio.fraction, source: "local-audio", reliable: true, audio: audio, sessionID: "session")
try store.saveAudiobook(book, progress: observation, interval: interval)
try require(try store.effectiveIntervals().map(\.duration) == [1800], "content must not inflate time")
try require(try store.archive().books.contains(old), "legacy book preserved")
let baseline = try store.archive()
var invalid = observation; invalid.id = "bad"; invalid.page = 8
let next = ReadingInterval(sessionID: "session", bookID: book.id, start: end, end: end.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .listening)
do { try store.saveAudiobook(book, progress: invalid, interval: next); fatalError("invalid mixed-unit evidence accepted") }
catch is ReadingStoreError {}
try require(try store.archive().intervals == baseline.intervals, "rollback interval")
try require(try store.effectiveIntervals().count == 1, "rollback cache")
var seek = observation; seek.id = "seek"; seek.sessionID = nil; seek.audio?.positionSeconds = 100; seek.fraction = seek.audio?.fraction
try store.saveAudiobook(book, progress: seek)
try require(try store.effectiveIntervals().count == 1, "seek credited time")
var clock = ListeningClock(); clock.start(date: end, uptime: 100)
try require(clock.checkpoint(date: end.addingTimeInterval(5), uptime: 105)?.seconds == 5, "elapsed clock")
try require(clock.checkpoint(date: end.addingTimeInterval(65), uptime: 165) == nil, "sleep credit")
try require(clock.checkpoint(date: end.addingTimeInterval(70), uptime: 170)?.seconds == 5, "clock recovery")
let export = root.appendingPathComponent("history.json")
try store.exportJSON(to: export)
let imported = try ReadingStore(url: root.appendingPathComponent("restored.sqlite"))
try imported.importJSON(from: export)
try require(try imported.archive().progress == store.archive().progress, "JSON round trip")
try require(try imported.archive().intervals.first?.audioSessionID == "session", "audio lineage JSON round trip")
let backup = root.appendingPathComponent("backup.sqlite")
try store.backup(to: backup)
try imported.restore(from: backup)
try require(try imported.archive().books == store.archive().books, "backup round trip")
let csv = root.appendingPathComponent("csv")
try store.exportCSV(to: csv)
try require(try String(contentsOf: csv.appendingPathComponent("progress.csv")).contains("content_position_seconds"), "CSV audio columns")
let groups = ReadingSessionGrouping.groups(intervals: [interval], merges: [])
try require(ReadingSessionGrouping.visibleGroups(groups, events: [], merges: []).count == 1, "listening session hidden")
print("audiobook-smoke passed: legacy decode, separate units, atomic rollback/cache, seeking, sleep, history visibility, JSON/CSV/backup")

import Foundation
import BooksCore

let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-background-store-\(UUID())")
defer { try? FileManager.default.removeItem(at: root) }
let url = root.appendingPathComponent("history.sqlite")
let store = try ReadingStore(url: url)
let book = BookRecord(id: "book", title: "Synthetic source validation")
try store.saveBook(book)
let date = Date(timeIntervalSince1970: 1_700_000_000)
let original = ReadingInterval(id: "original", sessionID: "session", bookID: book.id, start: date,
    end: date.addingTimeInterval(60), duration: 60, timezoneID: "UTC", mode: .automatic)
func event(_ interval: ReadingInterval, offset: Double = 0, session: String? = nil) -> AuditEvent {
    AuditEvent(date: interval.end.addingTimeInterval(offset), kind: "pageTurn", bookID: book.id,
        sessionID: session ?? interval.sessionID, detail: "Synthetic source check",
        pageTurn: PageTurnEvidence(fromPage: 1, toPage: 2, pagesRead: 1, visiblePages: 1, layoutSignature: "fixture"))
}
func reject(_ body: () throws -> Void) {
    do { try body(); fatalError("Invalid page source accepted") }
    catch ReadingStoreError.invalidData { }
    catch { fatalError("Unexpected error: \(error)") }
}
try store.appendInterval(original)
try store.appendEvent(event(original)) // cold source index
try store.appendEvent(event(original, offset: 0.0005))
reject { try store.appendEvent(event(original, offset: 0.002)) }
reject { try store.appendEvent(event(original, session: "wrong-session")) }
let replacement = ReadingInterval(id: "replacement", sessionID: "corrected", bookID: book.id,
    start: date, end: date.addingTimeInterval(30), duration: 30, timezoneID: "UTC", mode: .automatic)
try store.correct(IntervalCorrection(originalIDs: [original.id], replacements: [replacement], reason: "Synthetic trim"))
try store.appendEvent(event(original)) // Original evidence remains valid after correction.
try store.appendEvent(event(replacement))
let snapshot = try ReadingStore.readSnapshot(at: url)
precondition(snapshot.intervals.map(\.id) == [replacement.id])
precondition(snapshot.archive.intervals.map(\.id) == [original.id])
let backup = root.appendingPathComponent("backup.sqlite")
try store.backup(to: backup)
try store.deleteBook(book.id)
reject { try store.appendEvent(event(replacement)) }
try store.restore(from: backup)
try store.appendEvent(event(replacement))
try store.deleteAll()
try store.saveBook(book)
reject { try store.appendEvent(event(original)) }
let manual = ReadingInterval(id: "manual", sessionID: "manual", bookID: book.id,
    start: date, end: date.addingTimeInterval(60), duration: 60, timezoneID: "UTC", mode: .manual)
try store.appendInterval(manual)
reject { try store.appendEvent(event(manual)) }
// Import rebuilds a warm empty source index.
try store.deleteAll()
let imported = root.appendingPathComponent("import.json")
let backupStore = try ReadingStore(url: backup)
try backupStore.exportJSON(to: imported)
try store.importJSON(from: imported)
try store.appendEvent(event(replacement))
// A transaction that adds an automatic interval then fails must not leave a phantom source.
let audioBook = BookRecord(id: book.id, title: book.title, format: .audiobook)
let badProgress = ProgressObservation(bookID: book.id, observedAt: date.addingTimeInterval(180),
    page: 1, source: "local-audio", reliable: true, audio: AudiobookProgress(positionSeconds: 1, durationSeconds: 100), sessionID: "phantom")
let phantom = ReadingInterval(id: "phantom", sessionID: "phantom", bookID: book.id,
    start: date.addingTimeInterval(120), end: date.addingTimeInterval(180), duration: 60, timezoneID: "UTC", mode: .automatic)
do {
    try store.saveAudiobook(audioBook, progress: badProgress, interval: phantom)
    fatalError("Invalid mixed-unit progress accepted")
} catch ReadingStoreError.invalidData(let message) {
    // This error comes from appendProgress, after appendInterval mutated the source cache.
    precondition(message == "progress fraction must be between zero and one", "Did not reach progress insertion: \(message)")
}
let afterRollback = try store.archive()
precondition(!afterRollback.intervals.contains { $0.id == phantom.id })
precondition(afterRollback.books.first { $0.id == book.id }?.resolvedFormat == .text)
reject { try store.appendEvent(event(phantom)) }
try store.appendEvent(event(replacement))
// Read-only entry point must not create a missing database.
do { _ = try ReadingStore.readSnapshot(at: root.appendingPathComponent("missing.sqlite")); fatalError("Missing read succeeded") }
catch ReadingStoreError.sqlite { }
precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing.sqlite").path))
print("history-background-smoke passed: raw/corrected sources, endpoint tolerance, deletion, restore, read-only snapshot")

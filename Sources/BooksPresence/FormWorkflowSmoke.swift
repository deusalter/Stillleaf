import Foundation
import BooksCore
import CSQLite

private enum FormWorkflowSmokeError: Error { case failed(String) }

/// Exercise the result contracts that keep an editor open after a rejected save.
/// SQLite triggers simulate real write failures, not just invalid form input.
@MainActor
func checkFormSaveResults() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-form-check-" + UUID().uuidString)
    let suite = "Stillleaf.FormValidation." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = root.appendingPathComponent("history.sqlite")
    let source = BookRecord(id: "form-source", title: "A text edition")
    let target = BookRecord(id: "form-target", title: "Another text edition")
    var audio = BookRecord(id: "form-audio", title: "An audio edition")
    audio.format = .audiobook
    let end = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 86_400)
    let interval = ReadingInterval(sessionID: "form-session", bookID: source.id,
        start: end.addingTimeInterval(-1800), end: end, duration: 1800, timezoneID: "UTC", mode: .manual)
    do {
        let store = try ReadingStore(url: database)
        for book in [source, target, audio] { try store.saveBook(book) }
        try store.appendInterval(interval)
    }
    let model = try AppModel(support: root, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    let future = Date().addingTimeInterval(3600)
    guard !model.addManual(title: "Future", author: "", start: end, end: future), model.errorMessage != nil,
          !model.reviewInterval(interval, start: interval.start, end: future, bookID: source.id, disposition: .credited),
          !model.splitInterval(interval, at: interval.end),
          !model.mergeBooks(source: source, target: audio),
          !model.mergeBooks(source: audio, target: target),
          !model.startManual(title: "  ", author: "") else {
        throw FormWorkflowSmokeError.failed("An invalid form operation reported success")
    }

    var connection: OpaquePointer?
    guard sqlite3_open(database.path, &connection) == SQLITE_OK else {
        throw FormWorkflowSmokeError.failed("Could not open form failure fixture")
    }
    defer { sqlite3_close(connection) }
    let triggers = [("form_books", "INSERT", "books"), ("form_corrections", "INSERT", "corrections"),
                    ("form_merges", "INSERT", "merges"), ("form_deletion", "DELETE", "intervals")]
    for (name, operation, table) in triggers {
        let sql = "CREATE TRIGGER \(name) BEFORE \(operation) ON \(table) BEGIN SELECT RAISE(ABORT, 'synthetic form write failure'); END"
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw FormWorkflowSmokeError.failed("Could not install form failure fixture")
        }
    }
    let earlierEnd = end.addingTimeInterval(-86_400)
    let failures = [
        model.startManual(title: "Rejected start", author: ""),
        model.addManual(title: "Rejected addition", author: "", start: earlierEnd.addingTimeInterval(-600), end: earlierEnd),
        model.reviewInterval(interval, start: interval.start, end: interval.end, bookID: source.id, disposition: .excluded),
        model.splitInterval(interval, at: interval.start.addingTimeInterval(900)),
        model.mergeBooks(source: source, target: target),
        model.deleteSession(interval.sessionID)
    ]
    let failedArchive = try ReadingStore(url: database).archive()
    guard failures.allSatisfy({ !$0 }), model.errorMessage != nil,
          failedArchive.books.count == 3, failedArchive.intervals == [interval],
          failedArchive.corrections.isEmpty, failedArchive.merges.isEmpty else {
        throw FormWorkflowSmokeError.failed("A failed form save reported success or changed durable records")
    }
    for (name, _, _) in triggers {
        guard sqlite3_exec(connection, "DROP TRIGGER \(name)", nil, nil, nil) == SQLITE_OK else {
            throw FormWorkflowSmokeError.failed("Could not remove form failure fixture")
        }
    }
    guard model.addManual(title: "Saved addition", author: "", start: earlierEnd.addingTimeInterval(-600), end: earlierEnd),
          model.reviewInterval(interval, start: interval.start, end: interval.end, bookID: source.id, disposition: .excluded),
          let revised = model.intervals.first(where: { $0.sessionID == interval.sessionID }),
          model.splitInterval(revised, at: revised.start.addingTimeInterval(900)),
          model.mergeBooks(source: source, target: target),
          model.deleteSession(interval.sessionID), model.errorMessage == nil else {
        throw FormWorkflowSmokeError.failed("A form could not retry successfully after its write failure: \(model.errorMessage ?? "no error")")
    }
    print("ui-smoke: form results preserve validation failures, write failures and successful retries")
}

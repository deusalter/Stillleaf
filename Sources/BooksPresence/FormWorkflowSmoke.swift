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
    var failRecovery = false
    let model = try AppModel(support: root, defaults: defaults, startTracking: false,
        makeTrackingEngine: { store, zone in
            if failRecovery { throw FormWorkflowSmokeError.failed("Synthetic postcommit tracker recovery failure") }
            return try TrackingEngine(store: store, timezoneID: zone)
        })
    defer { model.shutdown() }
    let future = Date().addingTimeInterval(3600)
    guard !model.addManual(title: "Future", author: "", start: end, end: future), model.errorMessage != nil,
          !model.editInterval(interval, start: interval.start, end: future, bookID: source.id, disposition: .credited),
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
        model.editInterval(interval, start: interval.start, end: interval.end, bookID: source.id, disposition: .excluded),
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
          model.editInterval(interval, start: interval.start, end: interval.end, bookID: source.id, disposition: .excluded),
          let revised = model.intervals.first(where: { $0.sessionID == interval.sessionID }),
          model.splitInterval(revised, at: revised.start.addingTimeInterval(900)),
          model.mergeBooks(source: source, target: target),
          model.deleteSession(interval.sessionID), model.errorMessage == nil else {
        throw FormWorkflowSmokeError.failed("A form could not retry successfully after its write failure: \(model.errorMessage ?? "no error")")
    }
    // A durable save must still report success when the subsequent tracker
    // rebuild fails. Otherwise the retained editor can submit it a second time.
    failRecovery = true
    let recoveredEnd = earlierEnd.addingTimeInterval(-86_400)
    guard model.addManual(title: "Saved before recovery failed", author: "",
                          start: recoveredEnd.addingTimeInterval(-600), end: recoveredEnd),
          model.trackingRecoveryMessage?.contains("saved changes are intact") == true,
          let committedBook = model.books.first(where: { $0.title == "Saved before recovery failed" }),
          let committedInterval = model.intervals.first(where: { $0.bookID == committedBook.id }),
          model.intervals.filter({ $0.bookID == committedBook.id }).count == 1,
          model.editInterval(committedInterval, start: committedInterval.start, end: committedInterval.end,
                               bookID: committedBook.id, disposition: .excluded),
          model.trackingRecoveryMessage?.contains("saved changes are intact") == true,
          let corrected = model.intervals.first(where: { $0.bookID == committedBook.id }), corrected.disposition == .excluded,
          model.splitInterval(corrected, at: corrected.start.addingTimeInterval(300)),
          model.trackingRecoveryMessage?.contains("saved changes are intact") == true,
          model.intervals.filter({ $0.bookID == committedBook.id }).count == 2,
          model.deleteSession(corrected.sessionID),
          model.trackingRecoveryMessage?.contains("saved changes are intact") == true,
          !model.intervals.contains(where: { $0.sessionID == corrected.sessionID }),
          model.logAudiobook(book: audio, audio: AudiobookProgress(positionSeconds: 60, durationSeconds: 600),
                             start: nil, end: Date()),
          model.trackingRecoveryMessage?.contains("saved changes are intact") == true,
          model.audiobookProgress(for: audio.id)?.positionSeconds == 60 else {
        throw FormWorkflowSmokeError.failed("A committed form mutation was reported as retryable or hidden after tracker recovery failed")
    }
    let durable = try ReadingStore(url: database).archive()
    guard durable.books.filter({ $0.id == committedBook.id }).count == 1,
          durable.progress.contains(where: { $0.bookID == audio.id && $0.audio?.positionSeconds == 60 }),
          model.trackingRecoveryRequired, model.snapshot.phase == .paused,
          !model.audiobookPlayer.shouldCredit(audio.id), model.trackingEnabled else {
        throw FormWorkflowSmokeError.failed("Postcommit success was not durable")
    }
    var playbackBlocked = false
    do { try model.audiobookPlayer.willPlay?() } catch { playbackBlocked = true }
    guard playbackBlocked else { throw FormWorkflowSmokeError.failed("Playback resumed before tracker recovery") }
    guard !model.startManual(title: "Must not start during recovery", author: ""),
          !model.startManual(book: target), !model.manualActive,
          model.errorMessage?.contains("tracker recovers") == true,
          try ReadingStore(url: database).archive().books == durable.books else {
        throw FormWorkflowSmokeError.failed("Manual reading claimed to start or created a book while recovery blocked the tracker")
    }
    model.discordAssetKey = "form-recovery-fixture"
    model.saveSettings()
    guard model.errorMessage == nil, model.trackingRecoveryMessage != nil,
          defaults.string(forKey: "discordAssetKey") == "form-recovery-fixture" else {
        throw FormWorkflowSmokeError.failed("Tracker recovery status was mistaken for a failed independent settings save")
    }
    model.refresh(); model.refresh()
    let afterFailedRecovery = try ReadingStore(url: database).archive()
    guard model.trackingRecoveryRequired, model.trackingRecoveryMessage?.contains("saved changes are intact") == true,
          afterFailedRecovery.intervals == durable.intervals,
          afterFailedRecovery.corrections == durable.corrections,
          afterFailedRecovery.progress == durable.progress else {
        throw FormWorkflowSmokeError.failed("Retrying tracker recovery replayed a committed mutation or hid its failure")
    }
    failRecovery = false
    model.refresh()
    let afterRecovery = try ReadingStore(url: database).archive()
    guard !model.trackingRecoveryRequired, model.trackingRecoveryMessage == nil, model.errorMessage == nil, model.trackingEnabled,
          afterRecovery.intervals == durable.intervals,
          afterRecovery.corrections == durable.corrections,
          afterRecovery.progress == durable.progress else {
        throw FormWorkflowSmokeError.failed("Explicit recovery changed saved records or failed to release the tracking pause")
    }
    guard model.logAudiobook(book: audio, audio: AudiobookProgress(positionSeconds: 120, durationSeconds: 600),
                             start: nil, end: Date()), model.errorMessage == nil else {
        throw FormWorkflowSmokeError.failed("A subsequent successful tracker recovery retained the warning")
    }
    print("ui-smoke: form results distinguish validation/write failures from durable saves with failed tracker recovery")
}

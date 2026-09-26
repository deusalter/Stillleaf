import AppKit
import SwiftUI
import BooksCore
import BooksPlatform

/// Development-only integration test: isolated history, generated silent audio, no user app launch.
@MainActor
func runAudiobookSmoke(previews: URL) async throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ReadingStoreError.invalidData("audiobook smoke: " + message) }
    }
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-audio-smoke-" + UUID().uuidString)
    let suite = "Stillleaf.AudioSmoke." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: support) }
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let fixture = support.appendingPathComponent("Silent fixture.wav")
    var wav = Data()
    func ascii(_ text: String) { wav.append(contentsOf: text.utf8) }
    func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
    let bytes: UInt32 = 8000 * 2 * 30
    ascii("RIFF"); u32(36 + bytes); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
    u32(8000); u32(16000); u16(2); u16(16); ascii("data"); u32(bytes)
    wav.append(Data(count: Int(bytes))); try wav.write(to: fixture)
    let store = try ReadingStore(url: support.appendingPathComponent("history.sqlite"))
    let original = BookRecord(id: "existing-library-book", title: "The Quiet Hours", author: "Demo author")
    try store.saveBook(original)
    let model = try AppModel(support: support, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    let end = Date().addingTimeInterval(-3600)
    try require(model.logAudiobook(book: original, audio: AudiobookProgress(positionSeconds: 8100, durationSeconds: 36000),
        start: end.addingTimeInterval(-1800), end: end), "manual log: \(model.errorMessage ?? "")")
    try require(model.books.count == 1 && model.intervals.first?.duration == 1800, "existing book or independent session duration")
    try require(model.audiobookProgress(for: original.id)?.fraction == 0.225, "content fraction")
    try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
    try renderNativeView(AnyView(BookDetailView(model: model, book: model.books[0])),
        size: NSSize(width: 760, height: 720), appearance: NSAppearance(named: .aqua), to: previews.appendingPathComponent("audiobook-manual.png"))
    try renderNativeView(AnyView(AudiobookLogView(model: model, book: model.books[0])),
        size: NSSize(width: 550, height: 650), appearance: NSAppearance(named: .aqua), to: previews.appendingPathComponent("audiobook-log.png"))
    // A split retains listening identity on both halves, but only the half
    // containing a real checkpoint has a content endpoint. Reassignment must
    // never lend a different book that endpoint.
    let manual = model.intervals[0]
    model.splitInterval(manual, at: manual.start.addingTimeInterval(900))
    try require(model.intervals.count == 2 && model.intervals.allSatisfy { model.isListening($0) }, "split lost audio identity")
    let second = model.intervals.max { $0.end < $1.end }!
    let secondGroup = model.readingSessions.first { $0.intervals.contains { $0.id == second.id } }!
    try require(model.audiobookProgress(in: secondGroup)?.positionSeconds == 8100, "split lost position link")
    let target = BookRecord(id: "other", title: "Other book")
    try store.saveBook(target); model.refresh()
    model.reviewInterval(second, start: second.start, end: second.end, bookID: target.id, disposition: .credited)
    let reassigned = model.readingSessions.first { $0.bookID == target.id }!
    try require(model.audiobookProgress(in: reassigned) == nil, "reassignment leaked another book position")
    model.deleteBook(target)
    await model.importAudiobook(fixture, for: model.books[0])
    try require(model.errorMessage == nil && model.books[0].audioFileName != nil, "local import: \(model.errorMessage ?? "")")
    let originalBytes = try Data(contentsOf: fixture)
    try require(originalBytes == wav, "original changed")
    model.openAudiobook(model.books[0])
    model.audiobookPlayer.volume = 0
    model.audiobookPlayer.rate = 2
    model.audiobookPlayer.play()
    try require(model.audiobookPlayer.isPlaying, "native playback failed: \(model.audiobookPlayer.errorMessage ?? "")")
    try await Task.sleep(nanoseconds: 1_100_000_000)
    model.audiobookPlayer.seek(to: 15)
    try await Task.sleep(nanoseconds: 1_100_000_000)
    try model.audiobookPlayer.pause()
    let listening = model.intervals.filter { $0.mode == .listening }.reduce(0) { $0 + $1.duration }
    let position = model.audiobookProgress(for: original.id)!.positionSeconds
    try require(listening >= 2 && listening < 4, "2x playback inflated elapsed time: \(listening)")
    try require(position > 16 && position < 20, "seek/rate did not change content position: \(position)")
    try require(model.readingSessions.filter { $0.intervals.contains { $0.mode == .listening } }.allSatisfy { model.audiobookProgress(in: $0) != nil }, "session position linkage")
    let count = model.intervals.count
    try await Task.sleep(nanoseconds: 300_000_000)
    model.audiobookPlayer.seek(to: 5)
    try require(model.intervals.count == count, "paused seek added time")
    try model.audiobookPlayer.close()
    model.openAudiobook(model.books[0])
    try require(abs(model.audiobookPlayer.position - 5) < 0.1, "resume position")
    try renderNativeView(AnyView(BookDetailView(model: model, book: model.books[0])),
        size: NSSize(width: 760, height: 720), appearance: NSAppearance(named: .aqua), to: previews.appendingPathComponent("audiobook-player.png"))
    let reopened = try AppModel(support: support, defaults: defaults, startTracking: false)
    defer { reopened.shutdown() }
    reopened.openAudiobook(reopened.books[0])
    try require(abs(reopened.audiobookPlayer.position - 5) < 0.1, "resume after reopening database")
    model.audiobookPlayer.play()
    try await Task.sleep(nanoseconds: 300_000_000)
    model.setBookExclusions(model.books[0], tracking: true, sharing: false)
    try require(!model.audiobookPlayer.isPlaying && model.intervals.count > count, "exclusion discarded eligible time")
    let exclusionCount = model.intervals.count
    model.audiobookPlayer.play()
    try await Task.sleep(nanoseconds: 300_000_000)
    model.setBookExclusions(model.books[0], tracking: false, sharing: false)
    try require(!model.audiobookPlayer.isPlaying && model.intervals.count == exclusionCount, "exclusion toggle credited excluded time")
    model.trackingEnabled = false
    model.audiobookPlayer.play()
    try await Task.sleep(nanoseconds: 300_000_000)
    model.trackingEnabled = true
    try require(!model.audiobookPlayer.isPlaying && model.intervals.count == exclusionCount, "tracking transition credited disabled time")

    // Inject failure after a durable commit, then recover. Retrying must use the
    // same interval/observation IDs, so neither loss nor duplicate credit occurs.
    let persist = model.audiobookPlayer.persist!
    var failOnce = true
    var attempted: [String] = []
    var expectedRetryID: String?
    model.audiobookPlayer.persist = { observation, interval in
        attempted.append(observation.id)
        try persist(observation, interval)
        if failOnce {
            failOnce = false; expectedRetryID = observation.id
            throw ReadingStoreError.sqlite("injected acknowledgement failure")
        }
    }
    model.audiobookPlayer.play()
    try await Task.sleep(nanoseconds: 300_000_000)
    model.audiobookPlayer.pauseReportingErrors()
    let committedCount = model.intervals.count
    try require(model.audiobookPlayer.errorMessage != nil, "injected persistence failure did not pause")
    model.audiobookPlayer.play()
    try require(attempted.filter { $0 == expectedRetryID }.count == 2 && model.intervals.count == committedCount,
        "pending checkpoint was lost or duplicated on retry")
    try model.audiobookPlayer.pause()
    model.audiobookPlayer.persist = persist

    // Also fail before writing: retry must recover that elapsed interval.
    failOnce = true; expectedRetryID = nil; attempted = []
    model.audiobookPlayer.persist = { observation, interval in
        attempted.append(observation.id)
        if failOnce { failOnce = false; expectedRetryID = observation.id; throw ReadingStoreError.sqlite("injected write failure") }
        try persist(observation, interval)
    }
    let beforeFailure = model.intervals.count
    model.audiobookPlayer.play()
    try await Task.sleep(nanoseconds: 300_000_000)
    model.audiobookPlayer.pauseReportingErrors()
    try require(model.intervals.count == beforeFailure, "failed write unexpectedly committed")
    model.audiobookPlayer.play()
    try require(attempted.filter { $0 == expectedRetryID }.count == 2 && model.intervals.count == beforeFailure + 1,
        "unsaved listening interval was not retried")
    try model.audiobookPlayer.pause()
    model.audiobookPlayer.persist = persist
    model.audiobookPlayer.seek(to: model.audiobookPlayer.duration - 0.5)
    model.audiobookPlayer.play()
    try await Task.sleep(nanoseconds: 800_000_000)
    try require(!model.audiobookPlayer.isPlaying && abs(model.audiobookPlayer.position - 30) < 0.1, "end-of-file did not save final position")
    model.audiobookPlayer.seek(to: 5)
    model.audiobookPlayer.persist = { _, _ in throw ReadingStoreError.sqlite("injected persistent storage failure") }
    model.audiobookPlayer.play()
    try await Task.sleep(nanoseconds: 300_000_000)
    let failedQuit = await model.prepareReaderTermination()
    try require(!failedQuit && model.errorMessage != nil, "quit discarded a pending checkpoint")
    model.audiobookPlayer.persist = persist
    let recoveredQuit = await model.prepareReaderTermination()
    try require(recoveredQuit, "quit did not recover after storage resumed")
    let invalid = support.appendingPathComponent("invalid.mp3")
    try Data("not audio".utf8).write(to: invalid)
    await model.importAudiobook(invalid)
    try require(model.errorMessage != nil && model.books.count == 1, "invalid media accepted")
    let managed = try FileManager.default.contentsOfDirectory(at: support.appendingPathComponent("Audiobooks"), includingPropertiesForKeys: nil)
    try require(managed.count == 1, "failed import left a managed file")
    // Legacy linked IDs must never receive hidden audio records or lend text positions to audio cards.
    let linkedText = BookRecord(id: "linked-text-edition", title: original.title, source: "stillleaf-epub")
    try store.saveBook(linkedText)
    try store.merge(BookMerge(sourceID: linkedText.id, targetID: original.id))
    model.refresh()
    try require(model.canonicalLibraryBook(linkedText)?.id == original.id, "linked picker identity")
    try require(model.logAudiobook(book: linkedText, audio: AudiobookProgress(positionSeconds: 10, durationSeconds: 30),
        start: nil, end: Date()), "linked audio log")
    try require(model.audiobookProgress(for: linkedText.id) == nil, "hidden edition acquired audio progress")
    try require(model.audiobookProgress(for: original.id)?.positionSeconds == 10, "canonical audio position missing")
    try require(model.libraryProgressObservations[original.id]?.audio?.positionSeconds == 10, "card/detail audio source differs")
    print("audiobook-native-smoke passed: import/decode, existing-book manual log, 2x playback, seek/pause, persisted resume, corrupt-file rollback; elapsed=\(listening), content=\(position)")
}

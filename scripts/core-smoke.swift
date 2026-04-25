import Foundation
import Darwin
import BooksCore

enum SmokeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure.failed(message) }
}

func near(_ lhs: Double, _ rhs: Double, _ message: String) throws {
    try require(abs(lhs - rhs) < 0.001, "\(message): expected \(rhs), got \(lhs)")
}

func sameHistory(_ lhs: HistoryArchive, _ rhs: HistoryArchive) -> Bool {
    lhs.version == rhs.version && lhs.books == rhs.books && lhs.intervals == rhs.intervals
        && lhs.corrections == rhs.corrections && lhs.goals == rhs.goals && lhs.events == rhs.events
        && lhs.progress == rhs.progress && lhs.merges == rhs.merges
}

func input(_ date: Date, _ uptime: Double, _ book: BookRecord, activity: Bool = false) -> TrackingInput {
    TrackingInput(date: date, uptime: uptime, book: book, relevantActivity: activity)
}

func tick(_ engine: TrackingEngine, book: BookRecord, start: Date, uptime: Double, seconds: Int) throws {
    guard seconds > 0 else { return }
    for second in 1...seconds {
        try engine.process(input(start.addingTimeInterval(Double(second)), uptime + Double(second), book))
    }
}

func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BooksPresence-core-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ReadingStore(url: root.appendingPathComponent("history.sqlite"))
    print("storage opened")
    let book = BookRecord(id: "synthetic-book", title: "Synthetic Book", author: "Test Author")
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try store.saveBook(book)
    do {
        try store.appendInterval(ReadingInterval(sessionID: "invalid-point", bookID: book.id, start: start, end: start, duration: 1, timezoneID: "UTC", mode: .imported))
        throw SmokeFailure.failed("zero-span positive-duration interval was accepted")
    } catch is ReadingStoreError {}
    do {
        try store.appendInterval(ReadingInterval(sessionID: "invalid-inflated", bookID: book.id, start: start, end: start.addingTimeInterval(10), duration: 30, timezoneID: "UTC", mode: .imported))
        throw SmokeFailure.failed("inflated monotonic duration was accepted")
    } catch is ReadingStoreError {}

    let fractionalStore = try ReadingStore(url: root.appendingPathComponent("fractional.sqlite"))
    let fractionalDate = Date(timeIntervalSince1970: Double(bitPattern: 4_745_293_308_205_202_240))
    let fractionalBook = BookRecord(id: "fractional", title: "Fractional", observedAt: fractionalDate)
    try fractionalStore.saveBook(fractionalBook)
    let fractionalEvent = AuditEvent(id: "fractional-event", date: fractionalDate, kind: "synthetic", detail: "duplicate")
    try fractionalStore.appendEvent(fractionalEvent)
    try fractionalStore.appendEvent(fractionalEvent)
    let fractionalInterval = ReadingInterval(id: "fractional-interval", sessionID: "fractional-session", bookID: fractionalBook.id, start: fractionalDate, end: fractionalDate.addingTimeInterval(1.0000003), duration: 1, timezoneID: "UTC", mode: .imported)
    try fractionalStore.appendInterval(fractionalInterval)
    try fractionalStore.appendInterval(fractionalInterval)
    let fractionalArchive = try fractionalStore.archive()
    try require(fractionalArchive.events.filter { $0.id == fractionalEvent.id }.count == 1 && fractionalArchive.intervals.count == 1,
                "fractional timestamp duplicate was not canonicalized")
    var engine: TrackingEngine? = try TrackingEngine(store: store, timezoneID: "UTC", uncertaintyThreshold: 3, checkpointSeconds: 3)
    try engine!.process(input(start, 100, book))
    try tick(engine!, book: book, start: start, uptime: 100, seconds: 5)
    try engine!.process(TrackingInput(date: start.addingTimeInterval(5), uptime: 105, pauseReason: .background))
    try require(engine!.snapshot.phase == .paused && engine!.snapshot.book == book && engine!.snapshot.mode == .automatic,
                "background pause discarded the last reading snapshot")
    try engine!.process(input(start.addingTimeInterval(65), 165, book, activity: true))
    try tick(engine!, book: book, start: start.addingTimeInterval(65), uptime: 165, seconds: 2)
    try engine!.checkpoint(date: start.addingTimeInterval(67), uptime: 167)
    engine = nil

    let intervalsBeforeRecovery = try store.effectiveIntervals()
    try near(intervalsBeforeRecovery.filter { $0.disposition == .credited }.reduce(0) { $0 + $1.duration }, 5, "credited monotonic time")
    try near(intervalsBeforeRecovery.filter { $0.disposition == .uncertain }.reduce(0) { $0 + $1.duration }, 2, "uncertain monotonic time")
    try require(!intervalsBeforeRecovery.contains { $0.start < start.addingTimeInterval(65) && $0.end > start.addingTimeInterval(5) }, "pause gap was counted")

    _ = try TrackingEngine(store: store, timezoneID: "UTC")
    print("tracking and recovery checked")
    let recoveredArchive = try store.archive()
    try require(recoveredArchive.events.contains { $0.kind == "trackingRecovery" }, "crash recovery marker missing")
    try near(try store.effectiveIntervals().reduce(0) { $0 + $1.duration }, 7, "recovery invented elapsed time")

    let original = try store.effectiveIntervals().first!
    let replacement = ReadingInterval(id: "smoke-correction", sessionID: original.sessionID, bookID: original.bookID, start: original.start, end: original.end, duration: original.duration / 2, timezoneID: original.timezoneID, mode: original.mode, disposition: original.disposition)
    try store.correct(IntervalCorrection(originalIDs: [original.id], replacements: [replacement], reason: "synthetic trim"))
    let correctedArchive = try store.archive()
    try require(correctedArchive.corrections.count == 1, "correction provenance missing")

    let exportURL = root.appendingPathComponent("history.json")
    try store.exportJSON(to: exportURL)
    print("correction and export checked")
    let imported = try ReadingStore(url: root.appendingPathComponent("imported.sqlite"))
    try imported.importJSON(from: exportURL)
    let importedOnce = try imported.archive()
    try imported.importJSON(from: exportURL)
    let importedTwice = try imported.archive()
    try require(sameHistory(importedTwice, importedOnce), "duplicate import changed history")

    var invalid = HistoryArchive()
    invalid.books = [BookRecord(id: "bad-book", title: "Bad")]
    invalid.intervals = [
        ReadingInterval(id: "bad-a", sessionID: "a", bookID: "bad-book", start: start, end: start.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .imported),
        ReadingInterval(id: "bad-b", sessionID: "b", bookID: "bad-book", start: start.addingTimeInterval(5), end: start.addingTimeInterval(15), duration: 10, timezoneID: "UTC", mode: .imported)
    ]
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
    let invalidURL = root.appendingPathComponent("invalid.json")
    try encoder.encode(invalid).write(to: invalidURL)
    do {
        try imported.importJSON(from: invalidURL)
        throw SmokeFailure.failed("overlapping import succeeded")
    } catch is ReadingStoreError {}
    let afterInvalidImport = try imported.archive()
    try require(sameHistory(afterInvalidImport, importedOnce), "failed import was not atomic")
    print("imports checked")

    let backup = root.appendingPathComponent("backup.sqlite")
    try imported.backup(to: backup)
    print("backup created: \(FileManager.default.fileExists(atPath: backup.path))")
    try imported.saveBook(BookRecord(id: "temporary", title: "Temporary"))
    try imported.restore(from: backup)
    print("backup restored")
    let restoredArchive = try imported.archive()
    try require(!restoredArchive.books.contains { $0.id == "temporary" }, "restore did not replace live history")

    do {
        try imported.backup(to: root.appendingPathComponent("imported.sqlite"))
        throw SmokeFailure.failed("backup accepted the live database path")
    } catch is ReadingStoreError {}

    let deletionStore = try ReadingStore(url: root.appendingPathComponent("deletion.sqlite"))
    try deletionStore.saveBook(book)
    let deletionOriginal = ReadingInterval(id: "delete-original", sessionID: "original", bookID: book.id, start: start.addingTimeInterval(1_000), end: start.addingTimeInterval(1_020), duration: 20, timezoneID: "UTC", mode: .manual)
    let deletionFirst = ReadingInterval(id: "delete-first", sessionID: "keep", bookID: book.id, start: deletionOriginal.start, end: deletionOriginal.start.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .manual)
    let deletionSecond = ReadingInterval(id: "delete-second", sessionID: "remove", bookID: book.id, start: deletionFirst.end, end: deletionOriginal.end, duration: 10, timezoneID: "UTC", mode: .manual)
    try deletionStore.appendInterval(deletionOriginal)
    try deletionStore.correct(IntervalCorrection(originalIDs: [deletionOriginal.id], replacements: [deletionFirst, deletionSecond], reason: "split"))
    try deletionStore.deleteSession("remove")
    let deletionSurvivors = try deletionStore.effectiveIntervals()
    try require(deletionSurvivors == [deletionFirst], "deleting a split session lost or resurrected its sibling")

    let wallStore = try ReadingStore(url: root.appendingPathComponent("wall-clock.sqlite"))
    let wallEngine = try TrackingEngine(store: wallStore, timezoneID: "UTC")
    let wallStart = start.addingTimeInterval(5_000)
    try wallEngine.process(input(wallStart, 500, book))
    try wallEngine.process(input(wallStart.addingTimeInterval(1), 501, book))
    try wallEngine.process(input(wallStart.addingTimeInterval(-50), 502, book))
    try require(wallEngine.snapshot.pauseReason == .clockDiscontinuity, "backward wall clock did not pause")
    try wallEngine.process(input(wallStart.addingTimeInterval(1), 600, book))
    try wallEngine.process(input(wallStart.addingTimeInterval(2), 601, book))
    try wallEngine.stop(date: wallStart.addingTimeInterval(2), uptime: 601)
    try near(try wallStore.effectiveIntervals().reduce(0) { $0 + $1.duration }, 2, "backward wall clock overlap handling")

    var losAngeles = Calendar(identifier: .gregorian)
    losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let dstStart = losAngeles.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 23, minute: 30))!
    let dstEnd = losAngeles.date(from: DateComponents(year: 2025, month: 3, day: 9, hour: 3, minute: 30))!
    let dstInterval = ReadingInterval(sessionID: "dst", bookID: book.id, start: dstStart, end: dstEnd, duration: 10_800, timezoneID: "America/Los_Angeles", mode: .automatic)
    let dstDays = ReadingStatistics.daily(intervals: [dstInterval], goals: [], timezoneID: "America/Los_Angeles", from: dstStart, through: dstEnd)
    try require(dstDays.map(\.day) == ["2025-03-08", "2025-03-09"], "DST day keys incorrect")
    try near(dstDays[0].creditedSeconds, 1_800, "pre-midnight DST allocation")
    try near(dstDays[1].creditedSeconds, 9_000, "post-midnight DST allocation")

    let goalIntervals = [ReadingInterval(sessionID: "goal", bookID: book.id, start: utcDate(2025, 1, 1), end: utcDate(2025, 1, 1).addingTimeInterval(1_200), duration: 1_200, timezoneID: "UTC", mode: .manual)]
    let goalDays = ReadingStatistics.daily(intervals: goalIntervals, goals: [GoalChange(effectiveDay: "2025-01-02", minutes: 30)], timezoneID: "UTC", from: utcDate(2025, 1, 1), through: utcDate(2025, 1, 2))
    try require(goalDays.map(\.goalMinutes) == [20, 30], "goal change rewrote the past")
    let streak = ReadingStatistics.streak(days: goalDays, today: "2025-01-02")
    try require(streak.current == 1 && streak.todayPending, "pending-today streak semantics incorrect")

    print("BooksCore smoke checks passed")
} catch {
    fputs("BooksCore smoke check failed: \(error)\n", stderr)
    exit(1)
}

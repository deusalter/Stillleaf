import Foundation
import XCTest
@testable import BooksCore

final class BooksCoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
    }

    func testPauseDurationIsExcludedWhileSessionCanResume() throws {
        let store = try makeStore()
        let engine = try TrackingEngine(store: store, timezoneID: "UTC", checkpointSeconds: 15)
        let book = BookRecord(id: "book", title: "Synthetic")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try engine.process(input(start, 100, book))
        try tick(engine, book: book, date: start, uptime: 100, seconds: 4)
        try engine.process(TrackingInput(date: start.addingTimeInterval(4), uptime: 104, pauseReason: .background))
        try engine.process(input(start.addingTimeInterval(64), 164, book))
        try tick(engine, book: book, date: start.addingTimeInterval(64), uptime: 164, seconds: 4)
        try engine.stop(date: start.addingTimeInterval(68), uptime: 168)

        let intervals = try store.effectiveIntervals()
        XCTAssertEqual(intervals.reduce(0) { $0 + $1.duration }, 8, accuracy: 0.001)
        XCTAssertEqual(Set(intervals.map(\.sessionID)).count, 1)
        XCTAssertFalse(intervals.contains { $0.start < start.addingTimeInterval(64) && $0.end > start.addingTimeInterval(4) })
    }

    func testUncertainTimeIsSeparatedAndActivityDoesNotRetroactivelyCreditIt() throws {
        let store = try makeStore()
        let engine = try TrackingEngine(store: store, timezoneID: "UTC", uncertaintyThreshold: 3, checkpointSeconds: 15)
        let book = BookRecord(id: "book", title: "Synthetic")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try engine.process(input(start, 10, book))
        try tick(engine, book: book, date: start, uptime: 10, seconds: 6)
        try engine.process(TrackingInput(date: start.addingTimeInterval(7), uptime: 17, book: book, relevantActivity: true))
        try engine.process(input(start.addingTimeInterval(8), 18, book))
        try engine.stop(date: start.addingTimeInterval(8), uptime: 18)

        let intervals = try store.effectiveIntervals()
        let credited = intervals.filter { $0.disposition == .credited }.reduce(0) { $0 + $1.duration }
        let uncertain = intervals.filter { $0.disposition == .uncertain }.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(credited, 4, accuracy: 0.001)
        XCTAssertEqual(uncertain, 4, accuracy: 0.001)
        XCTAssertEqual(engine.snapshot.sessionSeconds, credited, accuracy: 0.001)
    }

    func testCrashRecoveryCreditsOnlyDurableCheckpointAndMarksUnknownTail() throws {
        let store = try makeStore()
        let book = BookRecord(id: "book", title: "Synthetic")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var engine: TrackingEngine? = try TrackingEngine(store: store, timezoneID: "UTC", checkpointSeconds: 3)
        try engine!.process(input(start, 50, book))
        try tick(engine!, book: book, date: start, uptime: 50, seconds: 3)
        engine = nil

        _ = try TrackingEngine(store: store, timezoneID: "UTC", checkpointSeconds: 3)
        XCTAssertEqual(try store.effectiveIntervals().reduce(0) { $0 + $1.duration }, 3, accuracy: 0.001)
        let recovery = try XCTUnwrap(store.archive().events.last(where: { $0.kind == "trackingRecovery" }))
        XCTAssertTrue(recovery.detail.contains("unknown"))
    }

    func testWallClockJumpDoesNotCreateReadingTime() throws {
        let store = try makeStore()
        let engine = try TrackingEngine(store: store, timezoneID: "UTC", checkpointSeconds: 15)
        let book = BookRecord(id: "book", title: "Synthetic")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try engine.process(input(start, 100, book))
        try engine.process(input(start.addingTimeInterval(1), 101, book))
        try engine.process(input(start.addingTimeInterval(3_601), 102, book))
        try engine.process(input(start.addingTimeInterval(3_602), 103, book))
        try engine.stop(date: start.addingTimeInterval(3_602), uptime: 103)
        XCTAssertEqual(try store.effectiveIntervals().reduce(0) { $0 + $1.duration }, 2, accuracy: 0.001)
        XCTAssertTrue(try store.archive().events.contains { $0.detail.contains(PauseReason.clockDiscontinuity.rawValue) })
    }

    func testBackwardWallClockJumpPausesUntilDurableWatermarkWithoutOverlap() throws {
        let store = try makeStore()
        let book = BookRecord(id: "book", title: "Synthetic")
        let start = Date(timeIntervalSince1970: 1_700_000_100)
        var engine = try TrackingEngine(store: store, timezoneID: "UTC", checkpointSeconds: 15)
        try engine.process(input(start, 100, book))
        try engine.process(input(start.addingTimeInterval(1), 101, book))
        try engine.process(input(start.addingTimeInterval(-50), 102, book))
        XCTAssertEqual(engine.snapshot.pauseReason, .clockDiscontinuity)
        try engine.process(input(start.addingTimeInterval(0.5), 200, book))
        XCTAssertEqual(engine.snapshot.phase, .paused)
        try engine.process(input(start.addingTimeInterval(1), 201, book))
        try engine.process(input(start.addingTimeInterval(2), 202, book))
        try engine.stop(date: start.addingTimeInterval(2), uptime: 202)
        XCTAssertEqual(try store.effectiveIntervals().reduce(0) { $0 + $1.duration }, 2, accuracy: 0.001)

        engine = try TrackingEngine(store: store, timezoneID: "UTC")
        try engine.process(input(start, 300, book))
        XCTAssertEqual(engine.snapshot.pauseReason, .clockDiscontinuity)
    }

    func testOverlapsAreRejectedAndFailedCheckpointWritesNoEvent() throws {
        let store = try makeStore()
        let book = BookRecord(id: "book", title: "Synthetic")
        try store.saveBook(book)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try store.appendInterval(ReadingInterval(id: "one", sessionID: "s1", bookID: book.id, start: start, end: start.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .automatic))
        XCTAssertThrowsError(try store.appendInterval(ReadingInterval(id: "two", sessionID: "s2", bookID: book.id, start: start.addingTimeInterval(5), end: start.addingTimeInterval(12), duration: 7, timezoneID: "UTC", mode: .automatic)))

        let existingMarker = AuditEvent(id: "must-rollback", kind: "trackingCheckpoint", detail: "existing")
        try store.appendEvent(existingMarker)
        let conflictingMarker = AuditEvent(id: existingMarker.id, kind: "trackingCheckpoint", detail: "conflict")
        XCTAssertThrowsError(try store.appendCheckpoint(interval: ReadingInterval(id: "rolled-back", sessionID: "s3", bookID: book.id, start: start.addingTimeInterval(10), end: start.addingTimeInterval(11), duration: 1, timezoneID: "UTC", mode: .automatic), event: conflictingMarker))
        XCTAssertFalse(try store.archive().intervals.contains { $0.id == "rolled-back" })
        XCTAssertEqual(try store.archive().events.first(where: { $0.id == existingMarker.id }), existingMarker)
    }

    func testCorrectionsRemainAuditableAndSessionDeletionRemovesDependents() throws {
        let store = try makeStore()
        let book = BookRecord(id: "book", title: "Synthetic")
        try store.saveBook(book)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = ReadingInterval(id: "original", sessionID: "session", bookID: book.id, start: start, end: start.addingTimeInterval(100), duration: 100, timezoneID: "UTC", mode: .manual)
        try store.appendInterval(original)
        let replacement = ReadingInterval(id: "trimmed", sessionID: "session", bookID: book.id, start: start, end: start.addingTimeInterval(40), duration: 40, timezoneID: "UTC", mode: .manual)
        try store.correct(IntervalCorrection(id: "correction", originalIDs: [original.id], replacements: [replacement], reason: "trim"))
        XCTAssertEqual(try store.effectiveIntervals(), [replacement])
        XCTAssertEqual(try store.archive().intervals, [original])

        try store.deleteSession("session")
        XCTAssertTrue(try store.effectiveIntervals().isEmpty)
        XCTAssertTrue(try store.archive().corrections.isEmpty)
    }

    func testDeletingOneSplitSessionPreservesItsEffectiveSibling() throws {
        let store = try makeStore()
        let book = BookRecord(id: "book", title: "Synthetic")
        try store.saveBook(book)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = ReadingInterval(id: "original", sessionID: "original-session", bookID: book.id, start: start, end: start.addingTimeInterval(20), duration: 20, timezoneID: "UTC", mode: .manual)
        let first = ReadingInterval(id: "first", sessionID: "first-session", bookID: book.id, start: start, end: start.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .manual)
        let second = ReadingInterval(id: "second", sessionID: "second-session", bookID: book.id, start: start.addingTimeInterval(10), end: start.addingTimeInterval(20), duration: 10, timezoneID: "UTC", mode: .manual)
        try store.appendInterval(original)
        try store.correct(IntervalCorrection(originalIDs: [original.id], replacements: [first, second], reason: "split"))

        try store.deleteSession(second.sessionID)
        XCTAssertEqual(try store.effectiveIntervals(), [first])
        XCTAssertTrue(try store.archive().corrections.isEmpty)
    }

    func testDeletingBookAcrossReassignmentDoesNotLoseTargetOrResurrectSource() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let store = try makeStore()
            let source = BookRecord(id: "source", title: "Source")
            let target = BookRecord(id: "target", title: "Target")
            try store.saveBook(source); try store.saveBook(target)
            let original = ReadingInterval(id: "original-a", sessionID: "session-a", bookID: source.id, start: start, end: start.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .manual)
            let reassigned = ReadingInterval(id: "reassigned-a", sessionID: "session-a", bookID: target.id, start: start, end: start.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .manual)
            try store.appendInterval(original)
            try store.correct(IntervalCorrection(originalIDs: [original.id], replacements: [reassigned], reason: "reassign"))
            try store.deleteBook(source.id)
            XCTAssertEqual(try store.effectiveIntervals(), [reassigned])
        }

        do {
            let store = try makeStore()
            let source = BookRecord(id: "source", title: "Source")
            let target = BookRecord(id: "target", title: "Target")
            try store.saveBook(source); try store.saveBook(target)
            let original = ReadingInterval(id: "original-b", sessionID: "session-b", bookID: source.id, start: start, end: start.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .manual)
            let reassigned = ReadingInterval(id: "reassigned-b", sessionID: "session-b", bookID: target.id, start: start, end: start.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .manual)
            try store.appendInterval(original)
            try store.correct(IntervalCorrection(originalIDs: [original.id], replacements: [reassigned], reason: "reassign"))
            try store.deleteBook(target.id)
            XCTAssertTrue(try store.effectiveIntervals().isEmpty)
            XCTAssertTrue(try store.archive().books.contains { $0.id == source.id })
        }
    }

    func testImportIsDuplicateSafeAndInvalidArchiveIsAtomic() throws {
        let source = try makeStore()
        let book = BookRecord(id: "book", title: "Comma, \"Quote\"")
        try source.saveBook(book)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try source.appendInterval(ReadingInterval(id: "one", sessionID: "s", bookID: book.id, start: start, end: start.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .imported))
        let directory = makeTemporaryDirectory()
        let export = directory.appendingPathComponent("history.json")
        try source.exportJSON(to: export)

        let destination = try makeStore()
        try destination.importJSON(from: export)
        let once = try destination.archive()
        try destination.importJSON(from: export)
        XCTAssertTrue(sameHistory(try destination.archive(), once))

        var bad = HistoryArchive()
        bad.books = [BookRecord(id: "new", title: "New")]
        bad.intervals = [
            ReadingInterval(id: "bad1", sessionID: "x", bookID: "new", start: start.addingTimeInterval(20), end: start.addingTimeInterval(30), duration: 10, timezoneID: "UTC", mode: .imported),
            ReadingInterval(id: "bad2", sessionID: "y", bookID: "new", start: start.addingTimeInterval(25), end: start.addingTimeInterval(35), duration: 10, timezoneID: "UTC", mode: .imported)
        ]
        let badURL = directory.appendingPathComponent("bad.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(bad).write(to: badURL)
        XCTAssertThrowsError(try destination.importJSON(from: badURL))
        XCTAssertTrue(sameHistory(try destination.archive(), once))
    }

    func testBackupRestoreRejectsDamageWithoutChangingLiveHistory() throws {
        let store = try makeStore()
        try store.saveBook(BookRecord(id: "kept", title: "Kept"))
        let directory = makeTemporaryDirectory()
        let backup = directory.appendingPathComponent("backup.sqlite")
        try store.backup(to: backup)
        try store.saveBook(BookRecord(id: "later", title: "Later"))
        try store.restore(from: backup)
        XCTAssertEqual(Set(try store.archive().books.map(\.id)), Set(["kept"]))

        let damaged = directory.appendingPathComponent("damaged.sqlite")
        try Data("not sqlite".utf8).write(to: damaged)
        XCTAssertThrowsError(try store.restore(from: damaged))
        XCTAssertEqual(Set(try store.archive().books.map(\.id)), Set(["kept"]))
    }

    func testCalendarSplitsAcrossMidnightAndDSTByAbsoluteElapsedTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 23, minute: 30))!
        let end = calendar.date(from: DateComponents(year: 2025, month: 3, day: 9, hour: 3, minute: 30))!
        XCTAssertEqual(end.timeIntervalSince(start), 10_800, accuracy: 0.001)
        let interval = ReadingInterval(sessionID: "s", bookID: "b", start: start, end: end, duration: 10_800, timezoneID: "America/Los_Angeles", mode: .automatic)
        let days = ReadingStatistics.daily(intervals: [interval], goals: [], timezoneID: "America/Los_Angeles", from: start, through: end)
        XCTAssertEqual(days.map(\.day), ["2025-03-08", "2025-03-09"])
        XCTAssertEqual(days[0].creditedSeconds, 1_800, accuracy: 0.001)
        XCTAssertEqual(days[1].creditedSeconds, 9_000, accuracy: 0.001)
    }

    func testGoalChangesDoNotRewritePastDaysAndTodayRemainsPending() {
        let from = utcDate(2025, 1, 1)
        let through = utcDate(2025, 1, 2, hour: 23)
        let intervals = [
            ReadingInterval(sessionID: "one", bookID: "b", start: from, end: from.addingTimeInterval(1_200), duration: 1_200, timezoneID: "UTC", mode: .automatic),
            ReadingInterval(sessionID: "two", bookID: "b", start: utcDate(2025, 1, 2), end: utcDate(2025, 1, 2).addingTimeInterval(1_200), duration: 1_200, timezoneID: "UTC", mode: .manual)
        ]
        let goals = [GoalChange(effectiveDay: "2025-01-02", minutes: 30)]
        let days = ReadingStatistics.daily(intervals: intervals, goals: goals, timezoneID: "UTC", from: from, through: through)
        XCTAssertEqual(days.map(\.goalMinutes), [20, 30])
        XCTAssertTrue(days[0].qualifies)
        XCTAssertFalse(days[1].qualifies)
        XCTAssertEqual(days[1].manualSeconds, 1_200, accuracy: 0.001)
        let streak = ReadingStatistics.streak(days: days, today: "2025-01-02")
        XCTAssertEqual(streak.current, 1)
        XCTAssertEqual(streak.longest, 1)
        XCTAssertTrue(streak.todayPending)
    }

    func testUnreliableRepeatedProgressIsStoredOnceAndDoesNotResetUncertainty() throws {
        let store = try makeStore()
        let engine = try TrackingEngine(store: store, timezoneID: "UTC", uncertaintyThreshold: 2, checkpointSeconds: 15)
        let book = BookRecord(id: "book", title: "Synthetic")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try engine.process(TrackingInput(date: start, uptime: 1, book: book, progress: ProgressObservation(id: "p0", bookID: book.id, observedAt: start, page: 10, source: "catalog", reliable: false)))
        for second in 1...4 {
            let date = start.addingTimeInterval(Double(second))
            try engine.process(TrackingInput(date: date, uptime: 1 + Double(second), book: book, progress: ProgressObservation(id: "p\(second)", bookID: book.id, observedAt: date, page: 10, source: "catalog", reliable: false)))
        }
        try engine.stop(date: start.addingTimeInterval(4), uptime: 5)
        XCTAssertEqual(try store.archive().progress.count, 1)
        XCTAssertEqual(try store.effectiveIntervals().filter { $0.disposition == .uncertain }.reduce(0) { $0 + $1.duration }, 2, accuracy: 0.001)
    }

    func testInsertionOrderWinsWhenWallClockMovesBackward() throws {
        let store = try makeStore()
        let book = BookRecord(id: "book", title: "Synthetic")
        try store.saveBook(book)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = ReadingInterval(id: "original", sessionID: "s", bookID: book.id, start: start, end: start.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .manual)
        let first = ReadingInterval(id: "first", sessionID: "s", bookID: book.id, start: start, end: start.addingTimeInterval(9), duration: 9, timezoneID: "UTC", mode: .manual)
        let second = ReadingInterval(id: "second", sessionID: "s", bookID: book.id, start: start, end: start.addingTimeInterval(8), duration: 8, timezoneID: "UTC", mode: .manual)
        try store.appendInterval(original)
        try store.correct(IntervalCorrection(id: "c1", createdAt: start.addingTimeInterval(100), originalIDs: [original.id], replacements: [first], reason: "first"))
        try store.correct(IntervalCorrection(id: "c2", createdAt: start.addingTimeInterval(50), originalIDs: [first.id], replacements: [second], reason: "second after clock rollback"))
        XCTAssertEqual(try store.effectiveIntervals(), [second])

        let goals = [
            GoalChange(id: "g1", effectiveDay: "2025-01-01", minutes: 20, createdAt: start.addingTimeInterval(100)),
            GoalChange(id: "g2", effectiveDay: "2025-01-01", minutes: 35, createdAt: start.addingTimeInterval(50))
        ]
        XCTAssertEqual(ReadingStatistics.daily(intervals: [], goals: goals, timezoneID: "UTC", from: utcDate(2025, 1, 1), through: utcDate(2025, 1, 1)).first?.goalMinutes, 35)

        let lifecycleStore = try makeStore()
        try lifecycleStore.appendEvent(AuditEvent(id: "start", date: start.addingTimeInterval(100), kind: "trackingStarted", detail: ""))
        try lifecycleStore.appendEvent(AuditEvent(id: "pause", date: start.addingTimeInterval(50), kind: "trackingPaused", detail: ""))
        _ = try TrackingEngine(store: lifecycleStore, timezoneID: "UTC")
        XCTAssertFalse(try lifecycleStore.archive().events.contains { $0.kind == "trackingRecovery" })
    }

    func testBackupAndExportRejectLiveDatabaseAliases() throws {
        let directory = makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let store = try ReadingStore(url: databaseURL)
        try store.saveBook(BookRecord(id: "book", title: "Synthetic"))
        XCTAssertThrowsError(try store.backup(to: databaseURL))
        XCTAssertThrowsError(try store.exportJSON(to: databaseURL))

        let symlink = directory.appendingPathComponent("database-alias")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: databaseURL)
        XCTAssertThrowsError(try store.backup(to: symlink))
        let hardlink = directory.appendingPathComponent("database-hardlink")
        try FileManager.default.linkItem(at: databaseURL, to: hardlink)
        XCTAssertThrowsError(try store.backup(to: hardlink))
    }

    func testImportMergesNewestBookMetadataAndRemainsIdempotent() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try store.saveBook(BookRecord(id: "book", title: "Old", observedAt: start))
        var imported = HistoryArchive()
        imported.exportedAt = start.addingTimeInterval(20)
        imported.books = [BookRecord(id: "book", title: "New", source: "catalog", observedAt: start.addingTimeInterval(10))]
        let url = makeTemporaryDirectory().appendingPathComponent("metadata.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(imported).write(to: url)
        try store.importJSON(from: url)
        let once = try store.archive()
        XCTAssertEqual(once.books.first?.title, "New")
        try store.importJSON(from: url)
        XCTAssertTrue(sameHistory(try store.archive(), once))
    }

    func testInvalidGoalsDatesAndHugeDurationsAreRejected() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.setGoal(GoalChange(effectiveDay: "2025-01-01", minutes: 0)))
        let book = BookRecord(id: "book", title: "Synthetic")
        try store.saveBook(book)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertThrowsError(try store.appendInterval(ReadingInterval(sessionID: "point", bookID: book.id, start: start, end: start, duration: 1, timezoneID: "UTC", mode: .imported)))
        XCTAssertThrowsError(try store.appendInterval(ReadingInterval(sessionID: "inflated", bookID: book.id, start: start, end: start.addingTimeInterval(10), duration: 30, timezoneID: "UTC", mode: .imported)))
        XCTAssertThrowsError(try store.appendInterval(ReadingInterval(sessionID: "s", bookID: book.id, start: start, end: start.addingTimeInterval(400 * 86_400), duration: 400 * 86_400, timezoneID: "UTC", mode: .imported)))
        XCTAssertThrowsError(try store.saveBook(BookRecord(id: "future", title: "Future", observedAt: Date(timeIntervalSince1970: 8_000_000_000))))
    }

    func testPointAndInflatedDurationImportsRejectAtomically() throws {
        let store = try makeStore()
        try store.saveBook(BookRecord(id: "kept", title: "Kept"))
        let before = try store.archive()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let directory = makeTemporaryDirectory()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970

        for interval in [
            ReadingInterval(id: "point", sessionID: "point", bookID: "bad", start: start, end: start, duration: 1, timezoneID: "UTC", mode: .imported),
            ReadingInterval(id: "inflated", sessionID: "inflated", bookID: "bad", start: start, end: start.addingTimeInterval(10), duration: 30, timezoneID: "UTC", mode: .imported)
        ] {
            var archive = HistoryArchive()
            archive.books = [BookRecord(id: "bad", title: "Bad")]
            archive.intervals = [interval]
            let url = directory.appendingPathComponent("\(interval.id).json")
            try encoder.encode(archive).write(to: url)
            XCTAssertThrowsError(try store.importJSON(from: url))
            XCTAssertTrue(sameHistory(try store.archive(), before))
        }
    }

    func testCSVIncludesEffectiveHistoryAndAuditTables() throws {
        let store = try makeStore()
        let book = BookRecord(id: "book", title: "Synthetic")
        try store.saveBook(book)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = ReadingInterval(id: "original", sessionID: "s", bookID: book.id, start: start, end: start.addingTimeInterval(10), duration: 10, timezoneID: "UTC", mode: .manual)
        let replacement = ReadingInterval(id: "replacement", sessionID: "s", bookID: book.id, start: start, end: start.addingTimeInterval(5), duration: 5, timezoneID: "UTC", mode: .manual)
        try store.appendInterval(original)
        try store.correct(IntervalCorrection(originalIDs: [original.id], replacements: [replacement], reason: "trim"))
        try store.appendProgress(ProgressObservation(bookID: book.id, page: 1, source: "synthetic", reliable: true))
        let directory = makeTemporaryDirectory()
        try store.exportCSV(to: directory)
        let effective = try String(contentsOf: directory.appendingPathComponent("effective_intervals.csv"))
        XCTAssertTrue(effective.contains("replacement"))
        XCTAssertFalse(effective.contains("original,"))
        for name in ["corrections.csv", "events.csv", "progress.csv"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
    }

    private func makeStore() throws -> ReadingStore {
        let directory = makeTemporaryDirectory()
        return try ReadingStore(url: directory.appendingPathComponent("history.sqlite"))
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BooksCoreTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func input(_ date: Date, _ uptime: TimeInterval, _ book: BookRecord) -> TrackingInput {
        TrackingInput(date: date, uptime: uptime, book: book)
    }

    private func tick(_ engine: TrackingEngine, book: BookRecord, date: Date, uptime: TimeInterval, seconds: Int) throws {
        for second in 1...seconds { try engine.process(input(date.addingTimeInterval(Double(second)), uptime + Double(second), book)) }
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func sameHistory(_ lhs: HistoryArchive, _ rhs: HistoryArchive) -> Bool {
        lhs.version == rhs.version && lhs.books == rhs.books && lhs.intervals == rhs.intervals
            && lhs.corrections == rhs.corrections && lhs.goals == rhs.goals && lhs.events == rhs.events
            && lhs.progress == rhs.progress && lhs.merges == rhs.merges
    }
}

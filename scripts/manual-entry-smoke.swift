import Foundation
import BooksCore

enum ManualEntrySmokeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case let .failed(message): return message } }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ManualEntrySmokeFailure.failed(message) }
}

private func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw ManualEntrySmokeFailure.failed(message)
}

private let zone = "UTC"
private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let dayKey = ReadingStatistics.dayKey(now.addingTimeInterval(-3_600), timezoneID: zone)

private func makeStore() throws -> (ReadingStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manual-entry-smoke-\(UUID().uuidString)")
    return (try ReadingStore(url: directory.appendingPathComponent("history.sqlite")), directory)
}

private func entry(book: String = "book", end: Date? = nil, minutes: Double = 0, pages: ManualPages? = nil,
                   total: Int? = nil) -> ManualReadingEntry {
    ManualReadingEntry(bookID: book, end: end ?? now.addingTimeInterval(-3_600), seconds: minutes * 60,
                       pages: pages, totalPages: total, timezoneID: zone)
}

do {
    // Pure validation.
    let existing = ReadingInterval(id: "auto", sessionID: "s", bookID: "other", start: now.addingTimeInterval(-7_200),
                                   end: now.addingTimeInterval(-5_400), duration: 1_800, timezoneID: zone, mode: .automatic)
    try require(entry().issue(existing: [], now: now) == .nothingToLog, "empty entry was accepted")
    try require(entry(minutes: 30).issue(existing: [], now: now) == nil, "time-only entry was rejected")
    try require(entry(pages: .count(12)).issue(existing: [], now: now) == nil, "pages-only entry was rejected")
    try require(entry(minutes: 30, pages: .count(12)).issue(existing: [], now: now) == nil, "time and pages were rejected")
    try require(entry(end: now.addingTimeInterval(600), minutes: 30).issue(existing: [], now: now) == .inFuture, "future end accepted")
    try require(entry(end: now.addingTimeInterval(600), pages: .count(3)).issue(existing: [], now: now) == .inFuture, "future pages accepted")
    try require(entry(minutes: 25 * 60).issue(existing: [], now: now) == .durationTooLong, "a day-plus session accepted")
    try require(entry(pages: .count(0)).issue(existing: [], now: now) == .pagesNotPositive, "zero pages accepted")
    try require(entry(pages: .range(from: 40, to: 40)).issue(existing: [], now: now) == .pagesNotPositive, "empty range accepted")
    try require(entry(pages: .range(from: 40, to: 30)).issue(existing: [], now: now) == .pagesNotPositive, "backwards range accepted")
    try require(entry(pages: .count(10_001)).issue(existing: [], now: now) == .pagesTooMany(limit: 10_000), "absurd page count accepted")
    try require(entry(pages: .range(from: 300, to: 350), total: 320).issue(existing: [], now: now) == .pageBeyondTotal(total: 320),
                "range past the book's last page accepted")
    try require(entry(pages: .range(from: 300, to: 320), total: 320).issue(existing: [], now: now) == nil, "range to the last page rejected")
    let overlapping = entry(end: now.addingTimeInterval(-5_000), minutes: 30)
    if case .overlaps? = overlapping.issue(existing: [existing], now: now) {} else { throw ManualEntrySmokeFailure.failed("overlap not detected") }
    try require(entry(end: now.addingTimeInterval(-3_000), minutes: 30).issue(existing: [existing], now: now) == nil,
                "a session that starts when another ends was called overlapping")
    try require(entry(end: now.addingTimeInterval(-5_000), pages: .count(5)).issue(existing: [existing], now: now) == nil,
                "pages-only entry was blocked by an overlapping session")

    // Records.
    let both = entry(minutes: 30, pages: .range(from: 10, to: 30), total: 300)
    let records = both.records(now: now)
    try require(records.interval.mode == .manual && records.interval.duration == 1_800, "time interval wrong")
    try require(records.interval.end == both.end && records.interval.start == both.end.addingTimeInterval(-1_800), "interval bounds wrong")
    try require(records.events.contains { $0.kind == "manualAddition" }, "manualAddition event missing")
    let adjustment = records.events.first { $0.kind == "manualPageAdjustment" }?.pageAdjustment
    try require(adjustment?.pages == 20 && adjustment?.fromPage == 10 && adjustment?.toPage == 30, "page evidence wrong")
    try require(records.progress?.page == 30 && records.progress?.totalPages == 300 && records.progress?.reliable == true, "progress wrong")
    let pagesOnly = entry(pages: .count(7)).records(now: now)
    try require(pagesOnly.interval.duration == 0 && pagesOnly.interval.end.timeIntervalSince(pagesOnly.interval.start) == 1, "marker wrong")
    try require(!pagesOnly.events.contains { $0.kind == "manualAddition" } && pagesOnly.progress == nil, "pages-only has stray records")
    try require(entry(minutes: 20).records(now: now).events.allSatisfy { $0.pageAdjustment == nil }, "time-only has page evidence")

    // Parsers.
    try require(ManualEntryParsing.duration("45") == 2_700, "45 is minutes")
    try require(ManualEntryParsing.duration("1h 20m") == 4_800 && ManualEntryParsing.duration("1h20") == 4_800, "1h 20m")
    try require(ManualEntryParsing.duration("1:30") == 5_400, "1:30 is one and a half hours")
    try require(ManualEntryParsing.duration("90 min") == 5_400 && ManualEntryParsing.duration("2 hours") == 7_200, "units")
    try require(ManualEntryParsing.duration("1.5h") == 5_400, "decimal hours")
    try require(ManualEntryParsing.duration("") == nil && ManualEntryParsing.duration("abc") == nil && ManualEntryParsing.duration("0") == nil, "bad durations")
    let pm = ManualEntryParsing.clock("7:42 pm"); try require(pm?.hour == 19 && pm?.minute == 42, "7:42 pm")
    let h24 = ManualEntryParsing.clock("19:42"); try require(h24?.hour == 19 && h24?.minute == 42, "19:42")
    let noon = ManualEntryParsing.clock("12 am"); try require(noon?.hour == 0 && noon?.minute == 0, "12 am")
    let compact = ManualEntryParsing.clock("742p"); try require(compact?.hour == 19 && compact?.minute == 42, "742p")
    try require(ManualEntryParsing.clock("25:00") == nil && ManualEntryParsing.clock("7:75") == nil && ManualEntryParsing.clock("x") == nil, "bad clocks")

    // Library matching.
    let library = [BookRecord(id: "1", title: "The Left Hand of Darkness", author: "Ursula K. Le Guin"),
                   BookRecord(id: "2", title: "Darkness at Noon", author: "Arthur Koestler"),
                   BookRecord(id: "3", title: "Piranesi", author: "Susanna Clarke"),
                   BookRecord(id: "4", title: "Dune (audio)", author: "Frank Herbert", format: .audiobook)]
    try require(LibraryBookMatcher.matches(query: "dark", in: library).map(\.id) == ["2", "1"], "title-prefix first, then contains")
    try require(LibraryBookMatcher.matches(query: "le guin", in: library).map(\.id) == ["1"], "author match")
    try require(LibraryBookMatcher.matches(query: "PIRANESI", in: library).map(\.id) == ["3"], "case-insensitive")
    try require(LibraryBookMatcher.matches(query: "dune", in: library, formats: [.text]).isEmpty, "format filter")
    try require(LibraryBookMatcher.matches(query: "  ", in: library).isEmpty, "blank query matches nothing")
    try require(LibraryBookMatcher.matches(query: "é", in: [BookRecord(id: "5", title: "Élan")]).count == 1, "diacritics fold")

    // Store: time + pages on a new outside book.
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outside = BookRecord(id: "openlibrary:OL1W", title: "Piranesi", author: "Susanna Clarke", source: "Open Library", pageCount: 272)
    try store.saveManualEntry(book: outside, records: entry(book: outside.id, minutes: 30, pages: .range(from: 10, to: 30), total: 272).records(now: now))
    var archive = try store.archive()
    try require(archive.books.first { $0.id == outside.id }?.pageCount == 272, "page count not stored")
    try require(archive.intervals.count == 1 && archive.events.contains { $0.pageAdjustment?.pages == 20 }, "entry not stored")
    try require(archive.progress.contains { $0.page == 30 }, "position not stored")
    let intervals = try store.effectiveIntervals()
    let pages = PageStatistics.snapshot(events: archive.events, effectiveIntervals: intervals, merges: [])
    try require(pages.pages(bookID: outside.id) == 20 && pages.pages(bookID: outside.id, manualOnly: true) == 20, "manual pages not counted for book")
    let goal = [GoalChange(effectiveDay: "2000-01-01", minutes: 20, pages: 20, primaryUnit: .pages)]
    let from = now.addingTimeInterval(-86_400), through = now
    let dayPages = pages.daily(goals: goal, timezoneID: zone, from: from, through: through)
    try require(dayPages.first { $0.day == dayKey }?.pages == 20 && dayPages.first { $0.day == dayKey }?.qualifies == true,
                "manual pages did not meet a page goal")
    let dayTime = ReadingStatistics.daily(intervals: intervals, goals: [], timezoneID: zone, from: from, through: through)
    try require(dayTime.first { $0.day == dayKey }?.creditedSeconds == 1_800 && dayTime.first { $0.day == dayKey }?.manualSeconds == 1_800, "manual time wrong")
    let pace = PageStatistics.pagesPerMinute(events: archive.events, effectiveIntervals: intervals, merges: [], bookID: outside.id)
    try require(pace == nil, "manual pages changed the automatic reading pace")

    // Store: pages only, inside another session's time. A zero-credit marker cannot conflict.
    let auto = ReadingInterval(id: "auto2", sessionID: "auto-session", bookID: outside.id, start: now.addingTimeInterval(-3_400),
                               end: now.addingTimeInterval(-2_400), duration: 1_000, timezoneID: zone, mode: .automatic)
    try store.appendInterval(auto)
    let marker = entry(book: outside.id, end: now.addingTimeInterval(-3_000), pages: .count(15))
    try store.saveManualEntry(book: outside, records: marker.records(now: now))
    archive = try store.archive()
    let all = try store.effectiveIntervals()
    let markerPages = PageStatistics.snapshot(events: archive.events, effectiveIntervals: all, merges: [])
    try require(markerPages.pages(bookID: outside.id) == 35, "pages-only entry lost: \(markerPages.pages(bookID: outside.id))")
    let timeAfter = ReadingStatistics.daily(intervals: all, goals: [], timezoneID: zone, from: from, through: through)
    try require(timeAfter.first { $0.day == dayKey }?.creditedSeconds == 2_800, "pages-only entry credited time")
    // Time cannot be double-booked through the store.
    try rejects("manual time overlapping a tracked session was accepted") {
        try store.appendInterval(ReadingInterval(sessionID: "t2", bookID: outside.id, start: now.addingTimeInterval(-3_900),
            end: now.addingTimeInterval(-3_100), duration: 800, timezoneID: zone, mode: .manual))
    }
    try rejects("overlapping manual time was stored") {
        try store.saveManualEntry(book: outside, records: entry(book: outside.id, end: now.addingTimeInterval(-3_200), minutes: 10).records(now: now))
    }
    let intervalCount = try store.archive().intervals.count
    try require(intervalCount == archive.intervals.count, "a rejected entry left an interval behind")

    // Observed page turns still need a tracked session; only a person's own count may sit on manual time.
    guard let manualInterval = archive.intervals.first(where: { $0.mode == .manual && $0.duration == 1_800 }) else {
        throw ManualEntrySmokeFailure.failed("manual interval missing")
    }
    try rejects("an observed page turn was accepted on a manual session") {
        try store.appendEvent(AuditEvent(date: manualInterval.end, kind: "pageTurn", bookID: outside.id, sessionID: manualInterval.sessionID,
            detail: "Observed", pageTurn: PageTurnEvidence(fromPage: 1, toPage: 2, pagesRead: 1, visiblePages: 1, layoutSignature: "smoke")))
    }

    // Evidence the store must refuse.
    func evidence(_ pages: Int, from: Int?, to: Int?) -> ManualEntryRecords {
        var records = entry(book: outside.id, end: now.addingTimeInterval(-10_000), pages: .count(5)).records(now: now)
        records.events = records.events.map { event in
            var copy = event
            copy.pageAdjustment = event.pageAdjustment.map {
                ManualPageAdjustmentEvidence(pages: pages, recordedAt: $0.recordedAt, reason: $0.reason, fromPage: from, toPage: to)
            }
            return copy
        }
        return records
    }
    try rejects("inconsistent page range accepted") { try store.saveManualEntry(book: outside, records: evidence(5, from: 10, to: 30)) }
    try rejects("half a page range accepted") { try store.saveManualEntry(book: outside, records: evidence(5, from: 10, to: nil)) }
    try store.saveManualEntry(book: outside, records: evidence(20, from: 10, to: 30))

    // Backups and exports keep page counts; older archives without them still load.
    let export = directory.appendingPathComponent("export.json")
    try store.exportJSON(to: export)
    let restored = try ReadingStore(url: directory.appendingPathComponent("restored.sqlite"))
    try restored.importJSON(from: export)
    let restoredCount = try restored.archive().books.first?.pageCount
    try require(restoredCount == 272, "page count lost in export")
    let legacy = try JSONDecoder().decode(BookRecord.self, from: Data(#"{"id":"x","title":"Old","source":"manual","observedAt":0,"trackingExcluded":false,"sharingExcluded":false}"#.utf8))
    try require(legacy.pageCount == nil, "legacy book gained a page count")
    let legacyEvidence = try JSONDecoder().decode(ManualPageAdjustmentEvidence.self, from: Data(#"{"pages":3,"recordedAt":0,"reason":"x"}"#.utf8))
    try require(legacyEvidence.fromPage == nil && legacyEvidence.toPage == nil, "legacy evidence gained a range")

    print("manual-entry-smoke: passed")
} catch ManualEntrySmokeFailure.failed(let message) {
    fputs("manual-entry-smoke: \(message)\n", stderr)
    exit(1)
} catch {
    fputs("manual-entry-smoke: \(error)\n", stderr)
    exit(1)
}

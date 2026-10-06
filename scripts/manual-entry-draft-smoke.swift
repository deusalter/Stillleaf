import Foundation
import BooksCore

enum DraftSmokeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case let .failed(message): return message } }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw DraftSmokeFailure.failed(message) }
}

@main
struct ManualEntryDraftSmoke {
    static func main() {
        do { try run(); print("manual-entry-draft-smoke: passed") }
        catch { fputs("manual-entry-draft-smoke: \(error)\n", stderr); exit(1) }
    }

    static func run() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let locale = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 23, minute: 49))!

        // Default: 30 minutes, finishing now.
        var draft = ManualEntryDraft()
        try require(draft.summary(book: nil, now: now, zone: zone, locale: locale) == "30 min · today, 11:19–11:49 PM", "default summary: \(draft.summary(book: nil, now: now, zone: zone, locale: locale) ?? "nil")")
        let built = draft.entry(bookID: "b", totalPages: nil, existing: [], now: now, zone: zone)
        try require(built.issue == nil && built.entry?.seconds == 1_800 && built.entry?.end == now, "default entry wrong")

        // Presets and custom.
        draft.preset = .hour
        try require(draft.summary(book: nil, now: now, zone: zone, locale: locale)?.hasPrefix("1 h · today") == true, "hour preset")
        draft.preset = .custom
        try require(draft.seconds(now: now, zone: zone).issue == .needsDuration, "custom empty")
        draft.customDuration = "1h 20m"
        try require(draft.seconds(now: now, zone: zone).value == 4_800, "custom 1h 20m")
        draft.customDuration = "banana"
        try require(draft.seconds(now: now, zone: zone).issue == .invalidDuration, "custom nonsense")

        // Crossing the meridiem keeps both suffixes.
        draft = ManualEntryDraft(); draft.finishClock = .init(hour: 0, minute: 10); draft.choose(day: .today)
        draft.finishClock = .init(hour: 0, minute: 10)
        let early = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 23, minute: 59))!
        try require(draft.summary(book: nil, now: early, zone: zone, locale: locale) == "30 min · today, 11:40 PM–12:10 AM", "meridiem crossing: \(draft.summary(book: nil, now: early, zone: zone, locale: locale) ?? "nil")")
        // 12:10 AM today is before 11:59 PM today, so that is a legitimate past time.
        try require(draft.entry(bookID: "b", totalPages: nil, existing: [], now: early, zone: zone).issue == nil, "past clock refused")

        // Other days default to the evening and show no "now".
        draft = ManualEntryDraft(); draft.choose(day: .yesterday)
        try require(draft.finishClock == ManualEntryDraft.eveningClock, "yesterday finish")
        try require(draft.summary(book: nil, now: now, zone: zone, locale: locale) == "30 min · yesterday, 7:30–8:00 PM", "yesterday summary: \(draft.summary(book: nil, now: now, zone: zone, locale: locale) ?? "nil")")
        draft.choose(day: .today); try require(draft.finishesNow, "today did not resume now")
        draft.choose(day: .other(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28))!))
        try require(draft.dayText(now: now, zone: zone, locale: locale) == "Mon, Sep 28", "date text: \(draft.dayText(now: now, zone: zone, locale: locale))")

        // A future finish is refused with the core's reason.
        draft = ManualEntryDraft(); draft.finishClock = .init(hour: 23, minute: 55)
        try require(draft.entry(bookID: "b", totalPages: nil, existing: [], now: now, zone: zone).issue == .entry(.inFuture), "future finish accepted")

        // Optional start time replaces the duration.
        draft = ManualEntryDraft(); draft.usesStartTime = true; draft.startClock = .init(hour: 22, minute: 45)
        try require(draft.seconds(now: now, zone: zone).value == 3_840, "start time duration: \(draft.seconds(now: now, zone: zone).value)")
        draft.startClock = .init(hour: 23, minute: 50)
        try require(draft.seconds(now: now, zone: zone).issue == .startNotBeforeFinish, "start after finish")

        // Pages: count, range, pages-only, both.
        draft = ManualEntryDraft(); draft.content = .pages; draft.pageCount = "20"
        try require(draft.summary(book: nil, now: now, zone: zone, locale: locale) == "20 pages · today", "pages-only summary: \(draft.summary(book: nil, now: now, zone: zone, locale: locale) ?? "nil")")
        let pagesOnly = draft.entry(bookID: "b", totalPages: nil, existing: [], now: now, zone: zone)
        try require(pagesOnly.issue == nil && pagesOnly.entry?.isPagesOnly == true, "pages-only entry")
        draft.content = .both; draft.pagesStyle = .range; draft.fromPage = "10"; draft.toPage = "30"
        try require(draft.summary(book: nil, now: now, zone: zone, locale: locale) == "30 min · 20 pages (p. 10–30) · today, 11:19–11:49 PM", "both summary: \(draft.summary(book: nil, now: now, zone: zone, locale: locale) ?? "nil")")
        draft.toPage = "400"
        try require(draft.entry(bookID: "b", totalPages: 320, existing: [], now: now, zone: zone).issue == .entry(.pageBeyondTotal(total: 320)), "past last page")
        draft.toPage = ""
        try require(draft.entry(bookID: "b", totalPages: nil, existing: [], now: now, zone: zone).issue == .needsPageRange, "incomplete range")
        draft.pagesStyle = .count; draft.pageCount = ""
        try require(draft.entry(bookID: "b", totalPages: nil, existing: [], now: now, zone: zone).issue == .needsPages, "missing pages")
        try require(ManualDraftIssue.needsPages.isIncomplete && !ManualDraftIssue.invalidDuration.isIncomplete, "incomplete flags")

        // Time-only ignores stale page fields.
        draft = ManualEntryDraft(); draft.pageCount = "abc"
        try require(draft.entry(bookID: "b", totalPages: nil, existing: [], now: now, zone: zone).issue == nil, "time-only read hidden page fields")

        // Overlap message names the clashing time.
        let clash = ReadingInterval(sessionID: "s", bookID: "o", start: now.addingTimeInterval(-3_000), end: now.addingTimeInterval(-1_200),
                                    duration: 1_800, timezoneID: zone.identifier, mode: .automatic)
        let overlap = ManualEntryDraft().entry(bookID: "b", totalPages: nil, existing: [clash], now: now, zone: zone)
        try require(overlap.issue?.message(zone: zone, locale: locale).contains("10:59–11:29 PM") == true, "overlap message: \(overlap.issue?.message(zone: zone, locale: locale) ?? "nil")")

        // Audiobook position.
        draft = ManualEntryDraft(); draft.kind = .audiobook
        try require(draft.audio().issue == .needsAudioPosition, "audio empty")
        draft.audioPosition = "2:15:00"; draft.audioTotal = "10:00:00"
        try require(draft.audio().value?.positionSeconds == 8_100, "audio parse")
        draft.audioPosition = "11:00:00"
        try require(draft.audio().issue == .invalidAudioPosition, "audio past end")
        try require(!draft.includesTime && !draft.includesPages, "audiobook defaults")

        // Clock stepping stays inside the day.
        try require(ManualEntryDraft.shifted(.init(hour: 23, minute: 58), minutes: 5) == .init(hour: 23, minute: 59), "shift upper clamp")
        try require(ManualEntryDraft.shifted(.init(hour: 0, minute: 2), minutes: -5) == .init(hour: 0, minute: 0), "shift lower clamp")
    }
}

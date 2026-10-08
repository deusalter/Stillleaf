import Foundation
import BooksCore

/// Exercised by macOS CI with synthetic data and the real publication controller.
@MainActor
func runHistoryAtlasNavigationSmoke(source: HistoryAtlasSource) throws {
    let ringPeriod = HistoryAtlasPeriod(source: source, navigation: CalendarNavigation(
        timezoneID: "UTC", anchor: source.intervals.first?.start ?? Date(), scale: .year))
    let ringEntries = Dictionary(ringPeriod.days.flatMap(\.books).map { ($0.bookID, $0) },
                                 uniquingKeysWith: { first, _ in first }).values.sorted { $0.bookID < $1.bookID }
    try checkHistoryRingRendering(entries: Array(ringEntries.prefix(3)))
    try checkCachedHistoryTitles()
    try checkMonthCivilDayIndex()
    try checkRecordedDateMenu()
    try checkHistoryYearRows()
    try checkRetainedHistoryNavigation(source: source)
    var pending: [CheckedContinuation<HistoryAtlasPeriod, Error>] = []
    var navigations: [CalendarNavigation] = []
    let controller = HistoryAtlasController { _, navigation in
        navigations.append(navigation)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    let anchor = source.intervals.first?.start ?? Date()
    var navigation = CalendarNavigation(timezoneID: "UTC", anchor: anchor, scale: .day)
    let day = navigation
    var tasks: [Task<Void, Never>] = []
    for scale in [CalendarScale.day, .year, .day] {
        navigation.setScale(scale)
        let request = navigation
        tasks.append(Task { await controller.load(source: source, navigation: request, reduceMotion: true) })
        try pumpAtlas { pending.count == tasks.count }
    }
    // ABA requests can have identical cache keys. The newest result wins by token.
    var heartbeat = false
    DispatchQueue.main.async { heartbeat = true }
    try pumpAtlas { heartbeat }
    pending[2].resume(returning: HistoryAtlasPeriod(source: source, navigation: day))
    try pumpAtlas { controller.presentation != nil }
    let expected = controller.presentation!.key
    pending[0].resume(returning: HistoryAtlasPeriod(source: source, navigation: navigations[0]))
    pending[1].resume(returning: HistoryAtlasPeriod(source: source, navigation: navigations[1]))
    var finished = false
    Task { for task in tasks { await task.value }; finished = true }
    try pumpAtlas { finished }
    guard controller.presentation?.key == expected else { throw AtlasSmokeFailure.stalePublication }

    // A cancelled request with no replacement must not publish either.
    var continuation: CheckedContinuation<HistoryAtlasPeriod, Error>?
    let cancelledController = HistoryAtlasController { _, _ in
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    let cancelled = Task { await cancelledController.load(source: source, navigation: day, reduceMotion: true) }
    try pumpAtlas { continuation != nil }
    cancelled.cancel()
    continuation!.resume(returning: HistoryAtlasPeriod(source: source, navigation: day))
    var cancelledFinished = false
    Task { await cancelled.value; cancelledFinished = true }
    try pumpAtlas { cancelledFinished }
    guard cancelledController.presentation == nil else { throw AtlasSmokeFailure.stalePublication }
    print("ui-smoke: History day → year → day, reversed completions, cancellation and main-queue heartbeat passed")
}

@MainActor
private func checkCachedHistoryTitles() throws {
    let parser = ISO8601DateFormatter()
    // Cross-year weeks and DST days exercise the calendar arithmetic; all
    // labels must remain identical to the uncached core navigation formatter.
    for timestamp in ["2025-12-31T23:30:00Z", "2026-03-08T10:01:00Z", "2026-11-01T09:01:00Z"] {
        let anchor = parser.date(from: timestamp)!
        for zone in ["UTC", "America/Los_Angeles", "Asia/Kathmandu"] {
            for scale in CalendarScale.allCases {
                let navigation = CalendarNavigation(timezoneID: zone, anchor: anchor, scale: scale)
                guard HistoryView.title(for: navigation) == navigation.title else { throw AtlasSmokeFailure.titleMismatch }
            }
        }
    }
}

@MainActor
private func checkMonthCivilDayIndex() throws {
    let zone = "America/Santiago"
    let anchor = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!
    let navigation = CalendarNavigation(timezoneID: zone, anchor: anchor, scale: .month)
    let calendar = navigation.calendar
    let book = BookRecord(id: "midnight-dst-book", title: "Midnight DST")
    let dates = [6, 7, 8].map {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: $0, hour: 12))!
    }
    let intervals = dates.enumerated().map { offset, start in
        let duration = Double(offset + 1) * 600
        return ReadingInterval(sessionID: "midnight-dst-\(offset)", bookID: book.id,
            start: start, end: start.addingTimeInterval(duration), duration: duration,
            timezoneID: zone, mode: .manual)
    }
    let source = HistoryAtlasSource(books: [book], intervals: intervals, events: [], progress: [], merges: [],
        finishedBooks: [], pageEvidence: PageStatistics.snapshot(events: [], effectiveIntervals: intervals, merges: []))
    let presentation = HistoryAtlasPeriod(source: source, navigation: navigation, now: anchor)
    let index = AtlasMonthView.indexDays(presentation, calendar: calendar)
    let cells = navigation.monthCells.filter(\.isInMonth)
    for (offset, date) in dates.enumerated() {
        let key = navigation.dayKey(for: date)
        guard let cell = cells.first(where: { calendar.isDate($0.date, inSameDayAs: date) }),
              let prepared = presentation.daysByKey[key] else {
            throw AtlasSmokeFailure.monthDayIndex("Missing source day \(key)")
        }
        // September 6 starts at 01:00, then cells return to midnight. Do not
        // require Foundation to preserve the shifted hour in prepared dates;
        // matching must work whether its day arithmetic normalizes it or not.
        guard calendar.component(.hour, from: cell.date) == (offset == 0 ? 1 : 0) else {
            throw AtlasSmokeFailure.monthDayIndex("Fixture did not exercise midnight DST on \(key)")
        }
        print("ui-smoke: \(key) prepared hour \(calendar.component(.hour, from: prepared.day.date)), grid hour \(calendar.component(.hour, from: cell.date))")
        for lookupDate in [cell.date, date] {
            guard let indexed = AtlasMonthView.day(for: lookupDate, in: index, calendar: calendar),
                  indexed.day.key == key,
                  indexed.day.creditedSeconds == Double(offset + 1) * 600 else {
                throw AtlasSmokeFailure.monthDayIndex("Recorded time missing or mapped to the wrong day on \(key)")
            }
        }
    }
    print("ui-smoke: Santiago midnight DST preserves September 6–8 month cells and same-day selection")
}

@MainActor
private func checkRetainedHistoryNavigation(source: HistoryAtlasSource) throws {
    var pending: [CheckedContinuation<HistoryAtlasPeriod, Error>] = []
    let controller = HistoryAtlasController { _, _ in
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    let anchor = source.intervals.first?.start ?? Date()
    let month = CalendarNavigation(timezoneID: "UTC", anchor: anchor, scale: .month)
    let first = Task { await controller.load(source: source, navigation: month, reduceMotion: true) }
    try pumpAtlas { pending.count == 1 }
    let monthData = HistoryAtlasPeriod(source: source, navigation: month)
    pending[0].resume(returning: monthData)
    try pumpAtlas { controller.displayed != nil }
    let year = CalendarNavigation(timezoneID: "UTC", anchor: anchor, scale: .year)
    let yearKey = HistoryAtlasKey(source: source, navigation: year)
    let second = Task { await controller.load(source: source, navigation: year, reduceMotion: true) }
    try pumpAtlas { pending.count == 2 }
    guard let retained = controller.displayed, retained.navigation == month,
          retained.presentation.key == monthData.key, retained.canRetain(for: yearKey),
          retained.presentation.key != yearKey else { throw AtlasSmokeFailure.stalePublication }

    // A timezone change or a new source revision must mask the old contents,
    // even while the view keeps their footprint to avoid a scrolling jump.
    let changedZone = CalendarNavigation(timezoneID: "Asia/Tokyo", anchor: anchor, scale: .month)
    let emptySource = HistoryAtlasSource(books: [], intervals: [], events: [], progress: [], merges: [],
        finishedBooks: [], pageEvidence: PageStatistics.snapshot(events: [], effectiveIntervals: [], merges: []))
    guard !retained.canRetain(for: HistoryAtlasKey(source: source, navigation: changedZone)),
          !retained.canRetain(for: HistoryAtlasKey(source: emptySource, navigation: month)),
          !retained.canRetain(for: HistoryAtlasKey(source: source, navigation: month, now: Date().addingTimeInterval(172_800))),
          !retained.canRetain(for: HistoryAtlasKey(source: source, navigation: month, localeID: "different-locale")) else {
        throw AtlasSmokeFailure.stalePublication
    }
    // Delete the source while navigation is pending. Its newer empty result
    // must win even if the earlier year result completes afterward.
    let third = Task { await controller.load(source: emptySource, navigation: month, reduceMotion: true) }
    try pumpAtlas { pending.count == 3 }
    let emptyData = HistoryAtlasPeriod(source: emptySource, navigation: month)
    pending[2].resume(returning: emptyData)
    try pumpAtlas { controller.presentation?.key == emptyData.key }
    pending[1].resume(returning: HistoryAtlasPeriod(source: source, navigation: year))
    var finished = false
    Task { await first.value; await second.value; await third.value; finished = true }
    try pumpAtlas { finished }
    guard controller.displayed?.navigation == month, controller.presentation?.key == emptyData.key,
          controller.presentation?.booksByID.isEmpty == true,
          controller.displayed?.animatesPeriodChange == false else { throw AtlasSmokeFailure.stalePublication }
    let fourth = Task { await controller.load(source: emptySource, navigation: year, reduceMotion: true) }
    try pumpAtlas { pending.count == 4 }
    let yearData = HistoryAtlasPeriod(source: emptySource, navigation: year)
    pending[3].resume(returning: yearData)
    try pumpAtlas { controller.presentation?.key == yearData.key }
    guard controller.displayed?.navigation == year, controller.displayed?.animatesPeriodChange == true else {
        throw AtlasSmokeFailure.stalePublication
    }
    var fourthFinished = false
    Task { await fourth.value; fourthFinished = true }
    try pumpAtlas { fourthFinished }
    print("ui-smoke: pending History retains matching navigation/data; timezone, revision, locale and day invalidate it; deletion wins late completion")
}

@MainActor
private func pumpAtlas(until finished: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(10)
    while !finished(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    guard finished() else { throw AtlasSmokeFailure.timeout }
}
private enum AtlasSmokeFailure: Error { case stalePublication, timeout, titleMismatch, monthDayIndex(String) }

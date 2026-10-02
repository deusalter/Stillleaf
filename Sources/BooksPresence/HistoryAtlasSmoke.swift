import Foundation
import BooksCore

/// Exercised by macOS CI with synthetic data and the real publication controller.
@MainActor
func runHistoryAtlasNavigationSmoke(source: HistoryAtlasSource) throws {
    try checkCachedHistoryTitles()
    try checkRecordedDateMenu()
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
private enum AtlasSmokeFailure: Error { case stalePublication, timeout, titleMismatch }

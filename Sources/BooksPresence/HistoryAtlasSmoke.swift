import Foundation
import BooksCore

/// Exercised by macOS CI with synthetic data and the real publication controller.
@MainActor
func runHistoryAtlasNavigationSmoke(source: HistoryAtlasSource) throws {
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
private func pumpAtlas(until finished: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(10)
    while !finished(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    guard finished() else { throw AtlasSmokeFailure.timeout }
}
private enum AtlasSmokeFailure: Error { case stalePublication, timeout }

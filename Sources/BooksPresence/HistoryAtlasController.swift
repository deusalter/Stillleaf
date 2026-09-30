import SwiftUI
import BooksCore

@MainActor
final class HistoryAtlasController: ObservableObject {
    @Published private(set) var presentation: HistoryAtlasPeriod?
    private let prepare: (HistoryAtlasSource, CalendarNavigation) async throws -> HistoryAtlasPeriod
    private var gate = HistoryAtlasRequestGate()

    init(prepare: ((HistoryAtlasSource, CalendarNavigation) async throws -> HistoryAtlasPeriod)? = nil) {
        let cache = HistoryAtlasCache()
        self.prepare = prepare ?? { source, navigation in
            try await cache.presentation(source: source, navigation: navigation)
        }
    }

    func load(source: HistoryAtlasSource, navigation: CalendarNavigation, reduceMotion: Bool) async {
        let token = gate.begin()
        do {
            // Let a burst of menu/navigation changes cancel before starting a scan.
            await Task.yield()
            try Task.checkCancellation()
            let prepared = try await prepare(source, navigation)
            guard gate.accepts(token), !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { presentation = prepared }
        } catch is CancellationError { /* The latest request owns the visible content. */ }
        catch { assertionFailure("Unexpected History presentation error: \(error)") }
    }
}

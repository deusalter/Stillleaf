import SwiftUI
import BooksCore

/// Navigation and data commit together: a retained chart never acquires the
/// requested period's heading or calendar while its replacement is preparing.
struct HistoryAtlasDisplay {
    let navigation: CalendarNavigation
    let presentation: HistoryAtlasPeriod
    let animatesPeriodChange: Bool

    func canRetain(for request: HistoryAtlasKey) -> Bool {
        let key = presentation.key
        return key.revision == request.revision && key.timezoneID == request.timezoneID
            && key.today == request.today && key.localeID == request.localeID
    }
}

@MainActor
final class HistoryAtlasController: ObservableObject {
    @Published private(set) var displayed: HistoryAtlasDisplay?
    var presentation: HistoryAtlasPeriod? { displayed?.presentation }
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
            // Views own their local transitions. Animating publication here also
            // animates summary layout and scroll geometry on every refresh.
            let compatible = displayed?.canRetain(for: prepared.key) == true
            displayed = HistoryAtlasDisplay(navigation: navigation, presentation: prepared,
                                            animatesPeriodChange: compatible)
        } catch is CancellationError { /* The latest request owns the visible content. */ }
        catch { assertionFailure("Unexpected History presentation error: \(error)") }
    }
}

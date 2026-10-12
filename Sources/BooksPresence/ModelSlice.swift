import BooksCore
import Combine
import Foundation

/// Invalidates a view only when a slice of the model changes. `AppModel` publishes on every
/// tracking tick, which would re-render and re-lay-out any view that observes it; a screen that
/// shows only history-derived data observes this instead and ignores ticks that change nothing it
/// shows. The key is read after the change has landed, on the next main-queue turn (which also
/// runs while a scroll or drag is tracking).
@MainActor
final class ModelSlice<Key: Equatable>: ObservableObject {
    private let key: (AppModel) -> Key
    private var current: Key
    private var subscription: AnyCancellable?

    init(model: AppModel, key: @escaping (AppModel) -> Key) {
        self.key = key
        current = key(model)
        subscription = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak model] _ in
                MainActor.assumeIsolated {
                    guard let self, let model else { return }
                    let next = self.key(model)
                    if next != self.current { self.current = next; self.objectWillChange.send() }
                }
            }
    }
}

/// What a screen derived only from the journal and the timezone depends on.
struct JournalSliceKey: Equatable {
    var revision: Int
    var timezoneID: String
    /// The day, for screens whose "today" must roll over at midnight.
    var day: String?

    @MainActor init(_ model: AppModel, tracksDay: Bool = false) {
        revision = model.historyRevision
        timezoneID = model.timezoneID
        day = tracksDay ? ReadingStatistics.dayKey(Date(), timezoneID: model.timezoneID) : nil
    }
}

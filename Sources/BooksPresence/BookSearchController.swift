import Foundation
import BooksPlatform

/// Drives the "Not in your library" results: waits for a pause in typing, cancels the request a
/// newer keystroke makes stale, and reports failure as a state rather than an error.
@MainActor
final class BookSearchController: ObservableObject {
    enum Failure: Equatable { case offline, timedOut, unavailable }

    enum Phase: Equatable {
        case idle
        case loading
        case results([OutsideBook])
        case failed(Failure)
    }

    @Published private(set) var phase: Phase = .idle

    private let service: BookSearchService
    private let debounce: UInt64
    private var task: Task<Void, Never>?
    private var query = ""
    private var cache: [String: [OutsideBook]] = [:]

    /// `initialPhase` lets previews show a state without waiting on a request.
    init(service: BookSearchService, debounce: TimeInterval = 0.35, initialPhase: Phase = .idle) {
        self.phase = initialPhase
        self.service = service
        self.debounce = UInt64(max(0, debounce) * 1_000_000_000)
    }

    /// Call whenever the search text changes.
    func update(query text: String) {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let key = normalized.lowercased()
        guard key != query || phase == .idle else { return }
        query = key
        task?.cancel()
        guard normalized.count >= 2 else { phase = .idle; return }
        if let cached = cache[key] { phase = .results(cached); return }
        start(normalized, key: key)
    }

    func retry() {
        guard query.count >= 2 else { return }
        start(query, key: query)
    }

    func cancel() {
        task?.cancel()
        task = nil
        query = ""
        phase = .idle
    }

    private func start(_ text: String, key: String) {
        phase = .loading
        let service = service, delay = debounce
        task = Task { [weak self] in
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                let found = try await service.search(text)
                try Task.checkCancellation()
                guard let self, self.query == key else { return }
                self.cache[key] = found
                self.phase = .results(found)
            } catch is CancellationError {
                return
            } catch let error as BookSearchError {
                guard let self, !Task.isCancelled, self.query == key else { return }
                switch error {
                case .offline: self.phase = .failed(.offline)
                case .timedOut: self.phase = .failed(.timedOut)
                default: self.phase = .failed(.unavailable)
                }
            } catch {
                guard let self, !Task.isCancelled, self.query == key else { return }
                self.phase = .failed(.unavailable)
            }
        }
    }
}

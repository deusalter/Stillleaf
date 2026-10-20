import Foundation
import BooksCore

/// Validates renderer messages for one open edition with the same rules as the Mac
/// reader window: only the session's main frame and token, only this edition,
/// fresh and strictly increasing progress sequences, and positions inside the spine.
struct ReaderEventGate {
    enum Event: Equatable {
        case available
        case ready
        case closeRequest
        case failed
        /// A validated reader-state snapshot, ready for `ReaderStateStore`.
        case state(Data)
        case position(NativeReaderPosition, ProgressObservation)
        /// A forward, sequential page departure: content coverage evidence.
        case forwardCoverage(PageTurnEvidence)
        case ignored
    }

    let publication: EPUBPublication
    let token: String
    private var lastSequence: UInt64 = 0

    init(publication: EPUBPublication, token: String) {
        self.publication = publication
        self.token = token
    }

    var bookID: String { "epub:" + publication.id }

    mutating func classify(_ body: Any, fromSessionMainFrame: Bool, now: Date = Date()) -> Event {
        guard fromSessionMainFrame, let body = body as? [String: Any], body["token"] as? String == token,
              let event = body["event"] as? [String: Any], let type = event["type"] as? String else { return .ignored }
        if type == "available" { return .available }
        guard event["editionId"] as? String == publication.id else { return .ignored }
        switch type {
        case "close-request": return .closeRequest
        case "ready": return .ready
        case "error": return .failed
        case "position", "pageTurn": return progress(event, type: type, now: now)
        case "state":
            guard let state = event["state"] as? [String: Any], JSONSerialization.isValidJSONObject(state),
                  let encoded = try? JSONSerialization.data(withJSONObject: state),
                  (try? ReaderStateValidation.validate(encoded, publication: publication)) != nil else { return .ignored }
            return .state(encoded)
        default:
            return .ignored
        }
    }

    private mutating func progress(_ event: [String: Any], type: String, now: Date) -> Event {
        guard let observed = event["observedAt"] as? Double, observed.isFinite,
              (-1...3).contains(now.timeIntervalSince1970 - observed / 1000),
              let number = event["sequence"] as? NSNumber,
              number.doubleValue > 0, number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded() == number.doubleValue,
              number.uint64Value > lastSequence else { return .ignored }
        lastSequence = number.uint64Value
        let key = type == "position" ? "position" : "departure"
        guard let value = event[key] as? [String: Any], JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let position = try? JSONDecoder().decode(NativeReaderPosition.self, from: data),
              position.isValid(spine: publication.spine) else { return .ignored }
        if key == "position" {
            guard let observation = position.observation(bookID: bookID, spine: publication.spine, date: now) else { return .ignored }
            return .position(position, observation)
        }
        guard event["direction"] as? String == "forward",
              let evidence = position.forwardCoverage(spine: publication.spine) else { return .ignored }
        return .forwardCoverage(evidence)
    }
}

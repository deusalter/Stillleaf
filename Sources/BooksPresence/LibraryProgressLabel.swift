import Foundation
import BooksCore

/// A content position, never accumulated reading/listening activity. The time
/// case is ready for an audiobook adapter without coupling cards to its storage.
enum LibraryContentPosition {
    case pages(current: Int, total: Int?)
    case time(current: TimeInterval, total: TimeInterval?)
    case fraction(Double)
}

struct LibraryProgressLabel: Equatable {
    let primary: String
    let detail: String?
    var accessibilityText: String { [primary, detail].compactMap { $0 }.joined(separator: ", ") }

    static func saved(_ observation: ProgressObservation?, pagesLogged: Int, finished: Bool) -> Self {
        if let observation, observation.reliable {
            if let page = observation.page,
               let label = position(.pages(current: page, total: observation.totalPages)) { return label }
            if let fraction = observation.fraction, let label = position(.fraction(fraction)) {
                let location = observation.location?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Self(primary: label.primary, detail: location?.isEmpty == false ? location : nil)
            }
        }
        if finished { return Self(primary: "Finished", detail: nil) }
        return Self(primary: pagesLogged > 0 ? "\(pagesLogged.formatted()) \(pagesLogged == 1 ? "page" : "pages") logged" : "Position unavailable",
                    detail: pagesLogged > 0 ? "Position unavailable" : nil)
    }

    static func position(_ position: LibraryContentPosition) -> Self? {
        switch position {
        case let .pages(current, total):
            guard current >= 0 else { return nil }
            guard let total else { return Self(primary: "Page \(current.formatted())", detail: "Total unavailable") }
            guard total > 0, current <= total else { return nil }
            return Self(primary: percent(Double(current) / Double(total)), detail: "\(current.formatted()) / \(total.formatted()) pages")
        case let .time(current, total):
            guard current.isFinite, current >= 0, current < Double(Int.max) else { return nil }
            guard let total else { return Self(primary: timestamp(current), detail: "Duration unavailable") }
            guard total.isFinite, total > 0, total < Double(Int.max), current <= total else { return nil }
            return Self(primary: percent(current / total), detail: "\(timestamp(current)) / \(timestamp(total))")
        case let .fraction(fraction):
            guard fraction.isFinite, (0...1).contains(fraction) else { return nil }
            return Self(primary: percent(fraction), detail: nil)
        }
    }

    private static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let value = Int(seconds)
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

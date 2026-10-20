import Foundation
import BooksCore

/// Short, consistent wording for durations, pages and goals across the app.
enum ReadingText {
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.down))
        if minutes < 1 { return seconds > 0 ? "<1 min" : "0 min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    static func pages(_ count: Int) -> String { count == 1 ? "1 page" : "\(count.formatted()) pages" }

    static func goalValue(_ progress: DailyGoalProgress) -> String {
        switch progress.unit {
        case .pages: return pages(Int(progress.value.rounded(.down)))
        case .minutes: return duration(progress.value * 60)
        }
    }

    static func goalTarget(_ progress: DailyGoalProgress) -> String? {
        guard let target = progress.target else { return nil }
        switch progress.unit {
        case .pages: return pages(Int(target))
        case .minutes: return duration(target * 60)
        }
    }

    static func stars(_ rating: Double) -> String {
        rating == rating.rounded() ? "\(Int(rating)) ★" : "\(rating.formatted(.number.precision(.fractionLength(0...2)))) ★"
    }

    /// The day a `ReadingStatistics.dayKey` names, at noon in the calendar time zone.
    static func date(dayKey: String, timezoneID: String) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

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

    /// "12 of 20 pages", or the value alone when no goal is set.
    static func goalSummary(_ progress: DailyGoalProgress) -> String {
        guard let target = progress.target else { return goalValue(progress) }
        switch progress.unit {
        case .pages: return "\(Int(progress.value.rounded(.down))) of \(pages(Int(target)))"
        case .minutes: return "\(Int(progress.value.rounded(.down))) of \(Int(target)) min"
        }
    }

    static func percent(_ fraction: Double) -> String { "\(Int((min(1, max(0, fraction)) * 100).rounded()))%" }

    /// "42% · Chapter 4 of 9": how far, and the chapter, without the page inside the chapter.
    static func place(fraction: Double, location: String?) -> String {
        let chapter = location?.components(separatedBy: " · ").first { !$0.hasPrefix("Page ") }
        return [percent(fraction), chapter].compactMap { $0 }.joined(separator: " · ")
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

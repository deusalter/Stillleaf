import Foundation

/// A local editing draft, never inferred from tracking sessions or the time an editor closes.
public struct ReadingCompletionDates: Equatable {
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(startedAt: Date? = nil, finishedAt: Date?) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public func validationMessage(now: Date) -> String? {
        for date in [startedAt, finishedAt].compactMap({ $0 }) {
            guard date.timeIntervalSince1970.isFinite,
                  date >= Self.earliestDate, date <= Self.latestDate else {
                return "Choose a date between 1900 and 2200."
            }
            if date > now { return "Reading dates cannot be in the future." }
        }
        if let start = startedAt, let finish = finishedAt, start > finish {
            return "The start date must be on or before the finish date."
        }
        return nil
    }

    public static let earliestDate = Date(timeIntervalSince1970: -2_208_988_800)
    public static let latestDate = Date(timeIntervalSince1970: 7_258_118_400)

    /// Selecting a different civil day keeps the recorded wall-clock time, using
    /// Calendar arithmetic across DST. Selecting the same day preserves the exact instant.
    public static func selecting(day: Date, preserving original: Date?, calendar: Calendar, now: Date) -> Date {
        if let original, calendar.isDate(day, inSameDayAs: original) { return original }
        let clock = calendar.dateComponents([.hour, .minute, .second], from: original ?? calendar.startOfDay(for: day))
        let result = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0,
                                   second: clock.second ?? 0, of: day) ?? calendar.startOfDay(for: day)
        return min(result, now)
    }
}

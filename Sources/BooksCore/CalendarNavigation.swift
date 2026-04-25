import Foundation

/// The presentation scale for reading history. Dates remain absolute instants;
/// this type only decides which calendar period is visible.
public enum CalendarScale: String, CaseIterable, Identifiable {
    case day, week, month, year

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }
}

public struct CalendarMonthCell: Identifiable, Equatable {
    public let date: Date
    public let isInMonth: Bool

    public var id: Date { date }

    public init(date: Date, isInMonth: Bool) {
        self.date = date
        self.isInMonth = isInMonth
    }
}

/// Calendar-safe navigation for History. It deliberately uses Calendar date
/// arithmetic so a move across daylight saving time or a leap day keeps the
/// user's local calendar anchor meaningful.
public struct CalendarNavigation: Equatable {
    public var timezoneID: String {
        didSet {
            guard timezoneID != oldValue else { return }
            // Keep the same absolute instant when a user changes timezone, but
            // make subsequent month/year navigation honor its newly displayed
            // local day rather than an old timezone's civil date.
            preferredDay = calendar.component(.day, from: anchor)
        }
    }
    public private(set) var anchor: Date
    public private(set) var scale: CalendarScale
    private var preferredDay: Int

    public init(timezoneID: String, anchor: Date = Date(), scale: CalendarScale = .month) {
        self.timezoneID = timezoneID
        self.anchor = anchor
        self.scale = scale
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        preferredDay = calendar.component(.day, from: anchor)
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        return calendar
    }

    public var periodStart: Date {
        switch scale {
        case .day:
            return calendar.startOfDay(for: anchor)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? calendar.startOfDay(for: anchor)
        case .month:
            return calendar.dateInterval(of: .month, for: anchor)?.start ?? calendar.startOfDay(for: anchor)
        case .year:
            return calendar.dateInterval(of: .year, for: anchor)?.start ?? calendar.startOfDay(for: anchor)
        }
    }

    public var period: DateInterval {
        switch scale {
        case .day:
            return calendar.dateInterval(of: .day, for: anchor) ?? DateInterval(start: periodStart, duration: 0)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: anchor) ?? DateInterval(start: periodStart, duration: 0)
        case .month:
            return calendar.dateInterval(of: .month, for: anchor) ?? DateInterval(start: periodStart, duration: 0)
        case .year:
            return calendar.dateInterval(of: .year, for: anchor) ?? DateInterval(start: periodStart, duration: 0)
        }
    }

    public var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = calendar.timeZone
        switch scale {
        case .day:
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
        case .week:
            let finalDay = calendar.date(byAdding: .day, value: -1, to: period.end) ?? period.end
            let sameYear = calendar.component(.year, from: period.start) == calendar.component(.year, from: finalDay)
            formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
            let start = formatter.string(from: period.start)
            formatter.dateFormat = "MMM d, yyyy"
            let end = formatter.string(from: finalDay)
            return "\(start) – \(end)"
        case .month:
            formatter.dateFormat = "MMMM yyyy"
        case .year:
            formatter.dateFormat = "yyyy"
        }
        return formatter.string(from: periodStart)
    }

    public var weekDates: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: periodStart) }
    }

    public var yearMonths: [Date] {
        let start = calendar.dateInterval(of: .year, for: anchor)?.start ?? periodStart
        return (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: start) }
    }

    /// Weekday-aligned cells for the visible month. The grid contains complete
    /// weeks, never more than six (42 cells).
    public var monthCells: [CalendarMonthCell] {
        let monthStart = calendar.dateInterval(of: .month, for: anchor)?.start ?? periodStart
        guard let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return [] }
        let weekdayOffset = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -weekdayOffset, to: monthStart) else { return [] }
        let usedDays = weekdayOffset + calendar.dateComponents([.day], from: monthStart, to: monthEnd).day!
        let count = min(42, ((usedDays + 6) / 7) * 7)
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            return CalendarMonthCell(date: date, isInMonth: calendar.isDate(date, equalTo: monthStart, toGranularity: .month))
        }
    }

    public func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    public mutating func setScale(_ scale: CalendarScale) {
        self.scale = scale
    }

    public mutating func select(_ date: Date, scale: CalendarScale? = nil) {
        anchor = date
        preferredDay = calendar.component(.day, from: date)
        if let scale { self.scale = scale }
    }

    public mutating func move(by value: Int) {
        let component: Calendar.Component
        switch scale {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        guard let shifted = calendar.date(byAdding: component, value: value, to: anchor) else { return }
        if scale == .month || scale == .year {
            var components = calendar.dateComponents([.year, .month, .hour, .minute, .second, .nanosecond], from: shifted)
            let daysInTargetMonth = calendar.range(of: .day, in: .month, for: shifted)?.count ?? preferredDay
            components.day = min(preferredDay, daysInTargetMonth)
            anchor = calendar.date(from: components) ?? shifted
        } else {
            anchor = shifted
            preferredDay = calendar.component(.day, from: anchor)
        }
    }

    public mutating func goToToday(_ now: Date = Date()) {
        anchor = now
        preferredDay = calendar.component(.day, from: now)
    }
}

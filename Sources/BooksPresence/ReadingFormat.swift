import Foundation

enum ReadingFormat {
    static func observedPages(_ value: Int) -> String {
        "\(value) observed \(value == 1 ? "page" : "pages")"
    }

    static func pagePace(_ minutesPerPage: Double?) -> String? {
        guard let minutesPerPage, minutesPerPage.isFinite, minutesPerPage > 0 else { return nil }
        if minutesPerPage < 1 {
            return "\(max(1, Int((60 / minutesPerPage).rounded()))) pages/hour"
        }
        return "\(minutesPerPage.formatted(.number.precision(.fractionLength(1)))) min/page"
    }

    static func pagesPerMinute(_ value: Double?) -> String? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return "\(value.formatted(.number.precision(.fractionLength(2)))) pages/min"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if rounded < 60 { return "\(rounded)s" }
        return "\(minutes)m"
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "Not yet recorded" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func day(_ string: String) -> String {
        guard let date = DayParser.date(string) else { return string }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

enum DayParser {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(_ value: String) -> Date? { formatter.date(from: value) }
}

/// Date labels in an explicit time zone, with formatters cached per format.
/// History, Timeline and the date editors draw many labels per pass, and
/// DateFormatter setup is the expensive part.
@MainActor
enum DateText {
    private enum Format: Hashable {
        case pattern(String)
        case styles(DateFormatter.Style, DateFormatter.Style)
    }
    private struct Key: Hashable {
        let locale: Locale
        let calendar: Calendar
        let zone: TimeZone
        let format: Format
    }
    private static var formatters: [Key: DateFormatter] = [:]
    private static let localeObserver = NotificationCenter.default.addObserver(
        forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
    ) { _ in
        // Preferences such as the hour cycle can change without a new locale ID.
        MainActor.assumeIsolated { formatters.removeAll(keepingCapacity: true) }
    }

    /// A fixed ICU pattern such as "EEEE, MMMM d".
    static func string(_ date: Date, zone: String, pattern: String) -> String {
        formatter(zone: zone, format: .pattern(pattern)).string(from: date)
    }

    /// The user's preferred date and time styles.
    static func string(_ date: Date, zone: String, date dateStyle: DateFormatter.Style,
                       time timeStyle: DateFormatter.Style = .none) -> String {
        formatter(zone: zone, format: .styles(dateStyle, timeStyle)).string(from: date)
    }

    private static func formatter(zone: String, format: Format) -> DateFormatter {
        // Capture current preferences on every lookup so a locale/calendar change
        // or a changed fallback timezone gets a new entry.
        _ = localeObserver
        let key = Key(locale: .current, calendar: .current,
                      zone: TimeZone(identifier: zone) ?? .current, format: format)
        if let formatter = formatters[key] { return formatter }
        let formatter = DateFormatter()
        formatter.locale = key.locale
        formatter.timeZone = key.zone
        switch format {
        case .pattern(let pattern): formatter.dateFormat = pattern
        case .styles(let date, let time): formatter.dateStyle = date; formatter.timeStyle = time
        }
        // Bound retained formatters even after repeated timezone/preference changes.
        if formatters.count >= 32 { formatters.removeAll(keepingCapacity: true) }
        formatters[key] = formatter
        return formatter
    }
}

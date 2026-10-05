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
    static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

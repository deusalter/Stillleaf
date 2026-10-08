import Foundation
import BooksCore

enum ManualEntryKind: String, CaseIterable, Hashable {
    case book = "Book"
    case audiobook = "Audiobook"
}

/// What the user is logging for a book: minutes, pages, or both.
enum ManualContent: String, CaseIterable, Hashable {
    case time = "Time"
    case pages = "Pages"
    case both = "Both"
}

enum ManualDayChoice: Equatable {
    case today
    case yesterday
    case other(Date)
}

enum DurationPreset: Int, CaseIterable, Hashable {
    case quarterHour = 15, halfHour = 30, threeQuarters = 45, hour = 60, custom = 0

    var label: String {
        switch self {
        case .quarterHour: return "15 min"
        case .halfHour: return "30 min"
        case .threeQuarters: return "45 min"
        case .hour: return "1 hour"
        case .custom: return "Custom"
        }
    }
}

enum ManualPagesStyle: String, CaseIterable, Hashable {
    case count = "Pages read"
    case range = "From – to"
}

/// Why a draft cannot be saved yet. `incomplete` problems are prompts, not errors.
enum ManualDraftIssue: Equatable {
    case chooseBook
    case needsTitle
    case needsDuration
    case invalidDuration
    case startNotBeforeFinish
    case needsPages
    case needsPageRange
    case needsAudioPosition
    case invalidAudioPosition
    case entry(ManualEntryIssue)

    var isIncomplete: Bool {
        switch self {
        case .chooseBook, .needsTitle, .needsDuration, .needsPages, .needsPageRange, .needsAudioPosition: return true
        default: return false
        }
    }
}

/// Everything the "Add reading time" form collects, and the rules that turn it into a saved entry.
/// Kept free of SwiftUI so the rules can be checked without a window.
struct ManualEntryDraft: Equatable {
    var kind: ManualEntryKind = .book
    var content: ManualContent = .time
    var day: ManualDayChoice = .today
    /// Nil means "now", and is only meaningful for today.
    var finishClock: ManualEntryParsing.Clock?
    var startClock = ManualEntryParsing.Clock(hour: 20, minute: 0)
    var usesStartTime = false
    var preset: DurationPreset = .halfHour
    var customDuration = ""
    var pagesStyle: ManualPagesStyle = .count
    var pageCount = ""
    var fromPage = ""
    var toPage = ""
    var logsListeningTime = false
    var audioPosition = ""
    var audioTotal = ""

    static let eveningClock = ManualEntryParsing.Clock(hour: 20, minute: 0)

    var includesTime: Bool { kind == .book ? content != .pages : logsListeningTime }
    var includesPages: Bool { kind == .book && content != .time }

    // MARK: Time

    func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    func dayStart(now: Date, zone: TimeZone) -> Date {
        let calendar = calendar(zone)
        let today = calendar.startOfDay(for: now)
        switch day {
        case .today: return today
        case .yesterday: return calendar.date(byAdding: .day, value: -1, to: today) ?? today
        case let .other(date): return calendar.startOfDay(for: date)
        }
    }

    private func moment(_ clock: ManualEntryParsing.Clock, now: Date, zone: TimeZone) -> Date? {
        calendar(zone).date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: dayStart(now: now, zone: zone))
    }

    var finishesNow: Bool { day == .today && finishClock == nil }

    func finish(now: Date, zone: TimeZone) -> Date? {
        if finishesNow { return now }
        return moment(finishClock ?? Self.eveningClock, now: now, zone: zone)
    }

    /// Seconds read, or the reason there are none yet.
    func seconds(now: Date, zone: TimeZone) -> (value: TimeInterval, issue: ManualDraftIssue?) {
        if usesStartTime {
            guard let end = finish(now: now, zone: zone), let start = moment(startClock, now: now, zone: zone), start < end else {
                return (0, .startNotBeforeFinish)
            }
            return (end.timeIntervalSince(start), nil)
        }
        if preset != .custom { return (TimeInterval(preset.rawValue) * 60, nil) }
        let text = customDuration.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return (0, .needsDuration) }
        guard let seconds = ManualEntryParsing.duration(text) else { return (0, .invalidDuration) }
        return (seconds, nil)
    }

    // MARK: Pages

    func pages() -> (value: ManualPages?, issue: ManualDraftIssue?) {
        func number(_ text: String) -> Int? { Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        switch pagesStyle {
        case .count:
            guard let count = number(pageCount) else { return (nil, .needsPages) }
            return (.count(count), nil)
        case .range:
            guard let from = number(fromPage), let to = number(toPage) else { return (nil, .needsPageRange) }
            return (.range(from: from, to: to), nil)
        }
    }

    // MARK: Entry

    /// The entry to save for a book, or the first thing standing in the way.
    func entry(bookID: String, totalPages: Int?, existing: [ReadingInterval], now: Date, zone: TimeZone)
        -> (entry: ManualReadingEntry?, issue: ManualDraftIssue?) {
        guard let end = finish(now: now, zone: zone) else { return (nil, .startNotBeforeFinish) }
        var seconds: TimeInterval = 0
        if includesTime {
            let result = self.seconds(now: now, zone: zone)
            if let issue = result.issue { return (nil, issue) }
            seconds = result.value
        }
        var pages: ManualPages?
        if includesPages {
            let result = self.pages()
            if let issue = result.issue { return (nil, issue) }
            pages = result.value
        }
        let entry = ManualReadingEntry(bookID: bookID, end: end, seconds: seconds, pages: pages,
                                       totalPages: totalPages, timezoneID: zone.identifier)
        if let issue = entry.issue(existing: existing, now: now) { return (entry, .entry(issue)) }
        return (entry, nil)
    }

    /// The listening position for an audiobook entry.
    func audio() -> (value: AudiobookProgress?, issue: ManualDraftIssue?) {
        let positionText = audioPosition.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalText = audioTotal.trimmingCharacters(in: .whitespacesAndNewlines)
        if positionText.isEmpty || totalText.isEmpty { return (nil, .needsAudioPosition) }
        guard let position = AudiobookProgress.parse(positionText), let total = AudiobookProgress.parse(totalText) else {
            return (nil, .invalidAudioPosition)
        }
        let progress = AudiobookProgress(positionSeconds: position, durationSeconds: total)
        return progress.isValid ? (progress, nil) : (nil, .invalidAudioPosition)
    }

    // MARK: Words

    /// "30 min · today, 11:19–11:49 PM", "20 pages · yesterday", "30 min · 20 pages · today, 8:00–8:30 PM".
    func summary(book: String?, now: Date, zone: TimeZone, locale: Locale = .current) -> String? {
        guard let end = finish(now: now, zone: zone) else { return nil }
        var parts: [String] = []
        var interval: (start: Date, end: Date)?
        if includesTime {
            let result = seconds(now: now, zone: zone)
            guard result.issue == nil else { return nil }
            parts.append(Self.durationText(result.value))
            interval = (end.addingTimeInterval(-result.value), end)
        }
        if includesPages {
            let result = pages()
            guard let value = result.value, result.issue == nil, value.count > 0 else { return nil }
            var text = "\(value.count) \(value.count == 1 ? "page" : "pages")"
            if case let .range(from, to) = value { text += " (p. \(from)–\(to))" }
            parts.append(text)
        }
        guard !parts.isEmpty else { return nil }
        let dayWord = dayText(now: now, zone: zone, locale: locale)
        if let interval {
            parts.append("\(dayWord), \(Self.clockRange(interval.start, interval.end, zone: zone, locale: locale))")
        } else {
            parts.append(dayWord)
        }
        return parts.joined(separator: " · ")
    }

    func dayText(now: Date, zone: TimeZone, locale: Locale = .current) -> String {
        switch day {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case let .other(date):
            let formatter = DateFormatter()
            formatter.locale = locale; formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
            return formatter.string(from: date)
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// "1h 20m" or "45m": the shape the custom length field reads back.
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "11:19–11:49 PM" when both ends share a meridiem, otherwise "11:40 PM–12:10 AM".
    static func clockRange(_ start: Date, _ end: Date, zone: TimeZone, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let from = plain(formatter.string(from: start)), to = plain(formatter.string(from: end))
        for symbol in [formatter.amSymbol, formatter.pmSymbol].compactMap({ $0 }) where from.hasSuffix(symbol) && to.hasSuffix(symbol) {
            let trimmed = from.dropLast(symbol.count).trimmingCharacters(in: .whitespaces)
            return "\(trimmed)–\(to)"
        }
        return "\(from)–\(to)"
    }

    static func clockText(_ clock: ManualEntryParsing.Clock, zone: TimeZone, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000)) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return plain(formatter.string(from: date))
    }

    /// Recent macOS puts a narrow no-break space before AM/PM; plain spaces read and compare predictably.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202f}", with: " ").replacingOccurrences(of: "\u{00a0}", with: " ")
    }
}

extension ManualEntryDraft {
    /// Moves a clock by whole minutes within the day.
    static func shifted(_ clock: ManualEntryParsing.Clock, minutes: Int) -> ManualEntryParsing.Clock {
        let total = min(23 * 60 + 59, max(0, clock.hour * 60 + clock.minute + minutes))
        return ManualEntryParsing.Clock(hour: total / 60, minute: total % 60)
    }

    /// Choosing another day swaps "now" for a fixed evening time; coming back to today resumes "now".
    mutating func choose(day: ManualDayChoice) {
        self.day = day
        if day == .today { finishClock = nil }
        else if finishClock == nil { finishClock = Self.eveningClock }
    }
}

extension ManualDraftIssue {
    func message(zone: TimeZone, locale: Locale = .current) -> String {
        switch self {
        case .chooseBook: return "Choose a book, or type a title to add one."
        case .needsTitle: return "Type the book's title."
        case .needsDuration: return "Enter how long you read, such as 45, 1h 20m or 1:30."
        case .invalidDuration: return "That length isn't clear. Try 45, 1h 20m or 1:30."
        case .startNotBeforeFinish: return "The start has to be earlier than the finish on the same day."
        case .needsPages: return "Enter how many pages you read."
        case .needsPageRange: return "Enter the page you started on and the page you stopped on."
        case .needsAudioPosition: return "Enter your place and the total length, such as 2:15:00 of 10:00:00."
        case .invalidAudioPosition: return "Your place has to be within the total length. Use hours:minutes:seconds."
        case let .entry(issue): return issue.message(zone: zone, locale: locale)
        }
    }
}

extension ManualEntryIssue {
    func message(zone: TimeZone, locale: Locale = .current) -> String {
        switch self {
        case .nothingToLog: return "Add some time, some pages, or both."
        case .pagesNotPositive: return "Pages must be at least 1, and the last page has to come after the first."
        case let .pagesTooMany(limit): return "That's more than \(limit.formatted()) pages in one entry. Split it across days."
        case let .pageBeyondTotal(total): return "This book has \(total.formatted()) pages, so that page doesn't exist."
        case .durationTooLong: return "A single entry can be at most 24 hours. Split longer reading across days."
        case .inFuture: return "That time hasn't happened yet. Pick a time that's already passed."
        case let .overlaps(start, end):
            return "You already have reading recorded from \(ManualEntryDraft.clockRange(start, end, zone: zone, locale: locale)). Pick a time that doesn't overlap it."
        }
    }
}

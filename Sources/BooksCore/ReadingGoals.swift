import Foundation

public enum ReadingGoals {
    public static func daily(day: String, pages: Int, creditedSeconds: Double,
                             goals: [GoalChange]) -> DailyGoalProgress {
        let active = goals.enumerated().filter { $0.element.effectiveDay <= day }.max { lhs, rhs in
            lhs.element.effectiveDay == rhs.element.effectiveDay ? lhs.offset < rhs.offset
                : lhs.element.effectiveDay < rhs.element.effectiveDay
        }?.element
        let unit = active?.resolvedUnit ?? .minutes
        let value = unit == .pages ? Double(max(0, pages)) : max(0, creditedSeconds) / 60
        let target: Double?
        switch unit {
        case .pages: target = active?.pages
        case .minutes: target = active?.minutes ?? 20
        }
        let validTarget = target.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let fraction = validTarget.map { min(1, value / $0) } ?? 0
        return DailyGoalProgress(unit: unit, value: value, target: validTarget,
                                 fraction: fraction, reached: validTarget.map { value >= $0 } ?? false)
    }

    public static func annualTarget(year: Int, events: [AuditEvent]) -> Int? {
        events.filter { $0.kind == "annualGoalChanged" && $0.annualGoal?.year == year }
            .max { lhs, rhs in lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date }?
            .annualGoal?.books
    }

    public static func finishedCount(year: Int, timezoneID: String, books: [BookRecord],
                                     events: [AuditEvent], merges: [BookMerge],
                                     now: Date = Date()) -> Int {
        guard (1...9999).contains(year) else { return 0 }
        let calendar = gregorianCalendar(timezoneID: timezoneID)
        let canonical = MergeResolver(merges: merges)
        let canonicalBooks = canonicalizedBooks(books, using: canonical)
        let canonicalEvents = events.map { event -> AuditEvent in
            guard event.kind == "bookCompleted", let bookID = event.bookID else { return event }
            var result = event
            result.bookID = canonical.resolve(bookID)
            return result
        }
        let ids = BookHistory.completedBooks(books: canonicalBooks, events: canonicalEvents).compactMap { entry -> String? in
            guard let finishedAt = entry.finishedAt, finishedAt <= now,
                  calendar.component(.year, from: finishedAt) == year else { return nil }
            return entry.id
        }
        return Set(ids).count
    }

    /// Keeps the first archive position for a merged identity while preferring
    /// the canonical target's own metadata when that record is available.
    private static func canonicalizedBooks(_ books: [BookRecord], using resolver: MergeResolver) -> [BookRecord] {
        var order: [String] = []
        var records: [String: BookRecord] = [:]
        for book in books {
            let canonicalID = resolver.resolve(book.id)
            var canonicalBook = book
            canonicalBook.id = canonicalID
            if records[canonicalID] == nil { order.append(canonicalID) }
            if records[canonicalID] == nil || book.id == canonicalID { records[canonicalID] = canonicalBook }
        }
        return order.compactMap { records[$0] }
    }

    private static func gregorianCalendar(timezoneID: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private struct MergeResolver {
        private var targets: [String: String] = [:]
        init(merges: [BookMerge]) {
            var latest: [String: Int] = [:]
            for (index, merge) in merges.enumerated() { latest[merge.sourceID] = index }
            for (index, merge) in merges.enumerated() where latest[merge.sourceID] == index && merge.active {
                targets[merge.sourceID] = merge.targetID
            }
        }
        func resolve(_ id: String) -> String {
            var current = id
            var visited = Set<String>()
            while let next = targets[current], visited.insert(current).inserted { current = next }
            return current
        }
    }
}

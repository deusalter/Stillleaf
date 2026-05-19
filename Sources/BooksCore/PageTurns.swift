import Foundation

/// A transient position from one verified reader layout. Page numbers in a
/// reflowable book are layout-specific and are never treated as canonical.
public struct ReaderPagePosition: Equatable {
    public var page: Int
    public var visiblePages: Int
    public var layoutSignature: String
    public init(page: Int, visiblePages: Int, layoutSignature: String) {
        self.page = page; self.visiblePages = visiblePages; self.layoutSignature = layoutSignature
    }
}

/// Durable evidence that two adjacent, short-interval samples moved forward.
public struct PageTurnEvidence: Codable, Equatable {
    public var fromPage: Int
    public var toPage: Int
    public var pagesRead: Int
    public var visiblePages: Int
    public var layoutSignature: String
    public init(fromPage: Int, toPage: Int, pagesRead: Int, visiblePages: Int, layoutSignature: String) {
        self.fromPage = fromPage; self.toPage = toPage; self.pagesRead = pagesRead
        self.visiblePages = visiblePages; self.layoutSignature = layoutSignature
    }
}

/// Counts only an immediately observed forward transition. Every rejected
/// sample becomes the next baseline, preventing jumps or gaps from backfilling.
public struct PageTurnTracker {
    private struct Baseline {
        var bookID: String
        var sessionID: String
        var position: ReaderPagePosition
        var date: Date
        var uptime: TimeInterval
    }

    public let maximumGap: TimeInterval
    private var baseline: Baseline?

    public init(maximumGap: TimeInterval = 5) {
        self.maximumGap = maximumGap.isFinite ? min(5, max(0, maximumGap)) : 5
    }

    public mutating func reset() { baseline = nil }

    public mutating func observe(bookID: String, sessionID: String, position: ReaderPagePosition,
                                 date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PageTurnEvidence? {
        guard Self.valid(position), !bookID.isEmpty, !sessionID.isEmpty,
              Self.valid(date), uptime.isFinite, uptime >= 0 else {
            reset()
            return nil
        }
        let current = Baseline(bookID: bookID, sessionID: sessionID, position: position, date: date, uptime: uptime)
        defer { baseline = current }
        guard let previous = baseline,
              previous.bookID == bookID, previous.sessionID == sessionID,
              previous.position.layoutSignature == position.layoutSignature,
              previous.position.visiblePages == position.visiblePages else { return nil }
        let uptimeDelta = uptime - previous.uptime
        let wallDelta = date.timeIntervalSince(previous.date)
        guard uptimeDelta >= 0, uptimeDelta <= maximumGap, wallDelta >= 0,
              abs(wallDelta - uptimeDelta) <= 2 else { return nil }
        let delta = position.page - previous.position.page
        guard delta >= 1, delta <= position.visiblePages else { return nil }
        return PageTurnEvidence(fromPage: previous.position.page, toPage: position.page,
                                pagesRead: delta, visiblePages: position.visiblePages,
                                layoutSignature: position.layoutSignature)
    }

    static func valid(_ position: ReaderPagePosition) -> Bool {
        position.page > 0 && position.page <= 10_000_000 && (1...2).contains(position.visiblePages)
            && !position.layoutSignature.isEmpty && position.layoutSignature.count <= 128
            && !position.layoutSignature.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func valid(_ evidence: PageTurnEvidence) -> Bool {
        let position = ReaderPagePosition(page: evidence.toPage, visiblePages: evidence.visiblePages,
                                          layoutSignature: evidence.layoutSignature)
        return valid(position) && evidence.fromPage > 0 && evidence.fromPage <= 10_000_000
            && evidence.pagesRead >= 1 && evidence.pagesRead <= evidence.visiblePages
            && evidence.toPage - evidence.fromPage == evidence.pagesRead
    }

    private static func valid(_ date: Date) -> Bool {
        let value = date.timeIntervalSince1970
        return value.isFinite && value >= -2_208_988_800 && value <= 7_258_118_400
    }
}

public enum PageStatistics {
    public static func daily(events: [AuditEvent], effectiveIntervals: [ReadingInterval], goals: [GoalChange],
                             merges: [BookMerge], timezoneID: String, from: Date, through: Date) -> [DailyPageTotal] {
        guard through >= from else { return [] }
        let calendar = calendar(timezoneID)
        let first = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: through)
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }

        var latestGoalByDay: [String: GoalChange] = [:]
        for goal in goals { latestGoalByDay[goal.effectiveDay] = goal }
        let goalDays = latestGoalByDay.keys.sorted()
        var activeGoal: Double?
        var goalIndex = 0
        var output: [DailyPageTotal] = []
        var indexByDay: [String: Int] = [:]
        var dayStart = first
        while dayStart <= last {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let key = dayKey(dayStart, timezoneID: timezoneID)
            while goalIndex < goalDays.count, goalDays[goalIndex] <= key {
                activeGoal = latestGoalByDay[goalDays[goalIndex]]?.pages
                goalIndex += 1
            }
            indexByDay[key] = output.count
            output.append(DailyPageTotal(day: key, pages: 0, goalPages: activeGoal))
            dayStart = nextDay
        }

        for item in qualified(events: events, effectiveIntervals: effectiveIntervals, merges: merges,
                              from: first, through: endExclusive, bookID: nil, sessionID: nil) {
            if let index = indexByDay[dayKey(item.event.date, timezoneID: timezoneID)] {
                output[index].pages += item.evidence.pagesRead
            }
        }
        return output
    }

    /// Returns observed pages in a half-open date range. Evidence counts only
    /// when it belongs to a surviving, non-excluded effective interval.
    public static func pages(events: [AuditEvent], effectiveIntervals: [ReadingInterval], merges: [BookMerge],
                             from: Date? = nil, through: Date? = nil,
                             bookID: String? = nil, sessionID: String? = nil) -> Int {
        if let from, let through, through < from { return 0 }
        return qualified(events: events, effectiveIntervals: effectiveIntervals, merges: merges,
                         from: from, through: through, bookID: bookID, sessionID: sessionID)
            .reduce(0) { $0 + $1.evidence.pagesRead }
    }

    /// Observed pages divided by confirmed foreground reading minutes. Both
    /// sides use only credited effective intervals, so uncertain time and its
    /// page evidence cannot make the pace appear faster or slower.
    public static func pagesPerMinute(events: [AuditEvent], effectiveIntervals: [ReadingInterval],
                                      merges: [BookMerge], bookID: String? = nil,
                                      sessionID: String? = nil) -> Double? {
        let resolver = MergeResolver(merges: merges)
        let requestedBook = bookID.map(resolver.resolve)
        let credited = effectiveIntervals.filter { interval in
            guard interval.mode == .automatic, interval.disposition == .credited,
                  interval.duration.isFinite, interval.duration > 0,
                  sessionID.map({ interval.sessionID == $0 }) ?? true else { return false }
            return requestedBook.map({ resolver.resolve(interval.bookID) == $0 }) ?? true
        }
        let seconds = credited.reduce(0) { $0 + $1.duration }
        guard seconds > 0 else { return nil }
        let observedPages = qualified(events: events, effectiveIntervals: credited, merges: merges,
                                      from: nil, through: nil, bookID: bookID, sessionID: sessionID)
            .reduce(0) { $0 + $1.evidence.pagesRead }
        guard observedPages > 0 else { return nil }
        return Double(observedPages) * 60 / seconds
    }

    public static func streak(days: [DailyPageTotal], today: String) -> StreakSummary {
        let ordered = days.sorted { $0.day < $1.day }
        var longest = 0
        var run = 0
        for day in ordered {
            if day.qualifies { run += 1; longest = max(longest, run) }
            else { run = 0 }
        }
        guard let todayIndex = ordered.lastIndex(where: { $0.day == today }) else {
            return StreakSummary(current: 0, longest: longest, todayPending: true, provisional: false)
        }
        let todayPending = !ordered[todayIndex].qualifies
        var cursor = todayPending ? todayIndex - 1 : todayIndex
        var current = 0
        while cursor >= 0 && ordered[cursor].qualifies {
            current += 1
            cursor -= 1
        }
        return StreakSummary(current: current, longest: longest, todayPending: todayPending, provisional: false)
    }

    private struct QualifiedPageTurn {
        var event: AuditEvent
        var evidence: PageTurnEvidence
    }

    private static func qualified(events: [AuditEvent], effectiveIntervals: [ReadingInterval], merges: [BookMerge],
                                  from: Date?, through: Date?, bookID: String?, sessionID: String?) -> [QualifiedPageTurn] {
        let resolver = MergeResolver(merges: merges)
        let requestedBook = bookID.map(resolver.resolve)
        let intervals = effectiveIntervals.filter { $0.disposition != .excluded }
        return events.compactMap { event in
            guard event.kind == "pageTurn", let evidence = event.pageTurn, PageTurnTracker.valid(evidence),
                  let eventBook = event.bookID, let eventSession = event.sessionID,
                  from.map({ event.date >= $0 }) ?? true, through.map({ event.date < $0 }) ?? true,
                  sessionID.map({ eventSession == $0 }) ?? true else { return nil }
            let resolvedBook = resolver.resolve(eventBook)
            guard requestedBook.map({ resolvedBook == $0 }) ?? true else { return nil }
            // Event dates are recorded at checkpoint end boundaries. `contains`
            // is start-exclusive so excluding the fragment that ended at an
            // event cannot retain it through the next fragment's start.
            guard intervals.contains(where: { interval in
                interval.sessionID == eventSession && resolver.resolve(interval.bookID) == resolvedBook
                    && event.date > interval.start && event.date <= interval.end
            }) else { return nil }
            return QualifiedPageTurn(event: event, evidence: evidence)
        }
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

    private static func dayKey(_ date: Date, timezoneID: String) -> String {
        let calendar = calendar(timezoneID)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func calendar(_ timezoneID: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.locale = Locale(identifier: "en_US_POSIX")
        result.timeZone = TimeZone(identifier: timezoneID) ?? TimeZone(secondsFromGMT: 0)!
        return result
    }
}

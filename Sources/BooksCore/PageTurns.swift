import Foundation

/// A transient position from one verified reader layout. Page numbers in a
/// reflowable book are layout-specific and are never treated as canonical.
public struct ReaderPagePosition: Equatable {
    public var page: Int
    /// A bounded navigation-capacity hint used only to cap burst inference.
    /// Adapters must not infer it from the number of chapter WebAreas, and it
    /// is not part of layout identity. The name remains for archive compatibility.
    public var visiblePages: Int
    public var layoutSignature: String
    public var totalPages: Int?
    public init(page: Int, visiblePages: Int, layoutSignature: String, totalPages: Int? = nil) {
        self.page = page; self.visiblePages = visiblePages; self.layoutSignature = layoutSignature
        self.totalPages = totalPages
    }
}

/// Durable traversal evidence: bounded external page samples or native screen
/// content. pagesRead is raw screen-page evidence; PageStatistics resolves novelty.
public struct PageTurnEvidence: Codable, Equatable {
    public var content: ReaderContentCoverage?
    public var totalPages: Int?
    public var fromPage: Int
    public var toPage: Int
    public var pagesRead: Int
    public var visiblePages: Int
    public var layoutSignature: String
    public init(fromPage: Int, toPage: Int, pagesRead: Int, visiblePages: Int, layoutSignature: String, totalPages: Int? = nil, content: ReaderContentCoverage? = nil) {
        self.content = content; self.totalPages = totalPages
        self.fromPage = fromPage; self.toPage = toPage; self.pagesRead = pagesRead
        self.visiblePages = visiblePages; self.layoutSignature = layoutSignature
    }
}

/// Counts bounded forward movement between two short-interval reader samples.
/// Every rejected sample becomes the next baseline, preventing jumps or gaps
/// from backfilling.
public struct PageTurnTracker {
    private struct Baseline {
        var bookID: String
        var sessionID: String
        var position: ReaderPagePosition
        var date: Date
        var uptime: TimeInterval
    }

    public let maximumGap: TimeInterval
    public static let maximumObservedPages = 8
    public static let minimumSecondsPerNavigation: TimeInterval = 0.25
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
        var normalizedPosition = position
        if let previous = baseline,
           previous.bookID == bookID, previous.sessionID == sessionID,
           previous.position.layoutSignature == position.layoutSignature,
           uptime >= previous.uptime, uptime - previous.uptime <= maximumGap,
           date >= previous.date,
           abs(date.timeIntervalSince(previous.date) - (uptime - previous.uptime)) <= 2,
           position.totalPages == nil,
           previous.position.totalPages.map({ position.page <= $0 }) ?? true {
            normalizedPosition.totalPages = previous.position.totalPages
        }
        let current = Baseline(bookID: bookID, sessionID: sessionID, position: normalizedPosition, date: date, uptime: uptime)
        defer { baseline = current }
        guard let previous = baseline,
              previous.bookID == bookID, previous.sessionID == sessionID,
              previous.position.layoutSignature == position.layoutSignature,
              previous.position.totalPages == normalizedPosition.totalPages,
              previous.position.totalPages.map({ position.totalPages != nil || position.page <= $0 }) ?? true else { return nil }
        let uptimeDelta = uptime - previous.uptime
        let wallDelta = date.timeIntervalSince(previous.date)
        guard uptimeDelta >= 0, uptimeDelta <= maximumGap, wallDelta >= 0,
              abs(wallDelta - uptimeDelta) <= 2 else { return nil }
        let delta = position.page - previous.position.page
        let navigationCapacity = max(1, Int(ceil(uptimeDelta / Self.minimumSecondsPerNavigation)))
        // A transient pane expansion is not proof that two physical pages were
        // traversed. Only capacity visible in both endpoint samples may widen
        // a burst beyond the single-pane bound.
        let sharedPaneCapacity = min(previous.position.visiblePages, position.visiblePages)
        let allowedPages = min(Self.maximumObservedPages, navigationCapacity * sharedPaneCapacity)
        guard delta >= 1, delta <= allowedPages else { return nil }
        return PageTurnEvidence(fromPage: previous.position.page, toPage: position.page,
                                pagesRead: delta, visiblePages: position.visiblePages,
                                layoutSignature: position.layoutSignature, totalPages: normalizedPosition.totalPages)
    }

    static func valid(_ position: ReaderPagePosition) -> Bool {
        position.page > 0 && position.page <= 10_000_000 && (1...2).contains(position.visiblePages)
            && (position.totalPages.map { $0 > 0 && $0 <= 10_000_000 && position.page <= $0 } ?? true)
            && !position.layoutSignature.isEmpty && position.layoutSignature.count <= 128
            && !position.layoutSignature.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func valid(_ evidence: PageTurnEvidence) -> Bool {
        let position = ReaderPagePosition(page: evidence.toPage, visiblePages: evidence.visiblePages,
                                          layoutSignature: evidence.layoutSignature)
        return valid(position) && (evidence.content?.isValid ?? true)
            && (evidence.totalPages.map { $0 >= evidence.toPage && $0 <= 10_000_000 } ?? true)
            && evidence.fromPage > 0 && evidence.fromPage <= 10_000_000
            && evidence.pagesRead >= 1 && evidence.pagesRead <= maximumObservedPages
            && evidence.toPage - evidence.fromPage == evidence.pagesRead
    }

    private static func valid(_ date: Date) -> Bool {
        let value = date.timeIntervalSince1970
        return value.isFinite && value >= -2_208_988_800 && value <= 7_258_118_400
    }
}

public enum PageStatistics {
    /// Prepares coverage once for a complete effective history. Display queries
    /// select already-qualified evidence, so earlier reading still prevents repeats.
    public struct Snapshot {
        private struct Entry {
            let date: Date
            let bookID: String
            let sessionID: String
            let pages: Int
            let manual: Bool
        }
        private let resolver: MergeResolver
        private let entries: [Entry]
        private let byBook: [String: [Entry]]
        private let bySession: [String: [Entry]]

        fileprivate init(events: [AuditEvent], effectiveIntervals: [ReadingInterval], merges: [BookMerge]) {
            let resolver = MergeResolver(merges: merges)
            self.resolver = resolver
            let entries = PageStatistics.qualified(events: events, effectiveIntervals: effectiveIntervals, merges: merges,
                from: nil, through: nil, bookID: nil, sessionID: nil).compactMap { item -> Entry? in
                    guard let bookID = item.event.bookID, let sessionID = item.event.sessionID else { return nil }
                    return Entry(date: item.event.date, bookID: resolver.resolve(bookID), sessionID: sessionID,
                        pages: item.pages, manual: item.event.pageAdjustment != nil)
                }
            self.entries = entries
            byBook = Dictionary(grouping: entries, by: \.bookID)
            bySession = Dictionary(grouping: entries, by: \.sessionID)
        }

        /// Builds daily totals from the same qualified coverage used by book/session queries.
        public func daily(goals: [GoalChange], timezoneID: String, from: Date, through: Date) -> [DailyPageTotal] {
            guard through >= from else { return [] }
            let calendar = PageStatistics.calendar(timezoneID)
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
                let key = PageStatistics.dayKey(dayStart, timezoneID: timezoneID)
                while goalIndex < goalDays.count, goalDays[goalIndex] <= key {
                    activeGoal = latestGoalByDay[goalDays[goalIndex]]?.pages
                    goalIndex += 1
                }
                indexByDay[key] = output.count
                output.append(DailyPageTotal(day: key, pages: 0, goalPages: activeGoal))
                dayStart = nextDay
            }

            for item in entries where item.date >= first && item.date < endExclusive {
                if let index = indexByDay[PageStatistics.dayKey(item.date, timezoneID: timezoneID)] {
                    output[index].pages += item.pages
                }
            }
            return output
        }

        public func pages(from: Date? = nil, through: Date? = nil, bookID: String? = nil,
                          sessionID: String? = nil, within selectedIntervals: [ReadingInterval]? = nil,
                          manualOnly: Bool = false) -> Int {
            if let from, let through, through < from { return 0 }
            let requestedBook = bookID.map(resolver.resolve)
            let candidates: [Entry]
            if let requestedBook { candidates = byBook[requestedBook] ?? [] }
            else if let sessionID { candidates = bySession[sessionID] ?? [] }
            else { candidates = entries }
            let selected = selectedIntervals.map { PageIntervalIndex(intervals: $0, resolve: resolver.resolve) }
            return candidates.reduce(0) { total, entry in
                guard sessionID.map({ entry.sessionID == $0 }) ?? true,
                      !manualOnly || entry.manual,
                      from.map({ entry.date >= $0 }) ?? true,
                      through.map({ entry.date < $0 }) ?? true,
                      selected?.contains(bookID: entry.bookID, sessionID: entry.sessionID, date: entry.date) ?? true else { return total }
                return total + entry.pages
            }
        }

        /// One pass over already-qualified evidence for a visible calendar period.
        /// Deduplication remains global; filtering never requalifies earlier pages.
        public func atlasTotals(period: DateInterval, timezoneID: String) -> AtlasPageTotals {
            var result = AtlasPageTotals()
            let calendar = PageStatistics.calendar(timezoneID)
            var boundaries: [(end: Date, key: String)] = []
            var start = calendar.startOfDay(for: period.start)
            while start < period.end {
                guard let end = calendar.date(byAdding: .day, value: 1, to: start), end > start else { break }
                boundaries.append((end, PageStatistics.dayKey(start, timezoneID: timezoneID)))
                start = end
            }
            guard !boundaries.isEmpty else { return result }
            // Snapshot entries are chronological. Move through civil boundaries
            // once, avoiding a timezone/calendar conversion for every page event.
            var index = 0
            for entry in entries where entry.date >= period.start && entry.date < period.end {
                while index + 1 < boundaries.count, entry.date >= boundaries[index].end { index += 1 }
                let key = boundaries[index].key
                result.pages += entry.pages
                result.byBook[entry.bookID, default: 0] += entry.pages
                result.byDay[key, default: 0] += entry.pages
                result.byDayBook[key, default: [:]][entry.bookID, default: 0] += entry.pages
            }
            return result
        }
    }

    public static func snapshot(events: [AuditEvent], effectiveIntervals: [ReadingInterval], merges: [BookMerge]) -> Snapshot {
        Snapshot(events: events, effectiveIntervals: effectiveIntervals, merges: merges)
    }

    public static func daily(events: [AuditEvent], effectiveIntervals: [ReadingInterval], goals: [GoalChange],
                             merges: [BookMerge], timezoneID: String, from: Date, through: Date) -> [DailyPageTotal] {
        snapshot(events: events, effectiveIntervals: effectiveIntervals, merges: merges)
            .daily(goals: goals, timezoneID: timezoneID, from: from, through: through)
    }

    /// Returns observed pages and explicit manual corrections in a half-open date range. Evidence counts only
    /// when it belongs to a surviving, non-excluded effective interval. Supply the
    /// complete effective history for coverage, then `within` to select display intervals.
    public static func pages(events: [AuditEvent], effectiveIntervals: [ReadingInterval], merges: [BookMerge],
                             from: Date? = nil, through: Date? = nil,
                             bookID: String? = nil, sessionID: String? = nil,
                             within selectedIntervals: [ReadingInterval]? = nil) -> Int {
        if let from, let through, through < from { return 0 }
        return qualified(events: events, effectiveIntervals: effectiveIntervals, merges: merges,
                         from: from, through: through, bookID: bookID, sessionID: sessionID, selectedIntervals: selectedIntervals)
            .reduce(0) { $0 + $1.pages }
    }

    public static func manualPages(events: [AuditEvent], effectiveIntervals: [ReadingInterval], merges: [BookMerge],
                                   from: Date? = nil, through: Date? = nil,
                                   bookID: String? = nil, sessionID: String? = nil) -> Int {
        qualified(events: events, effectiveIntervals: effectiveIntervals, merges: merges,
                  from: from, through: through, bookID: bookID, sessionID: sessionID)
            .filter { $0.event.pageAdjustment != nil }.reduce(0) { $0 + $1.pages }
    }

    /// Observed pages divided by confirmed foreground reading minutes. Both
    /// sides use only credited effective intervals, so uncertain time and its
    /// page evidence cannot make the pace appear faster or slower.
    public static func pagesPerMinute(events: [AuditEvent], effectiveIntervals: [ReadingInterval],
                                      merges: [BookMerge], bookID: String? = nil,
                                      sessionID: String? = nil, within selectedIntervals: [ReadingInterval]? = nil) -> Double? {
        let resolver = MergeResolver(merges: merges)
        let requestedBook = bookID.map(resolver.resolve)
        let credited = effectiveIntervals.filter { interval in
            guard interval.mode == .automatic, interval.disposition == .credited,
                  interval.duration.isFinite, interval.duration > 0,
                  sessionID.map({ interval.sessionID == $0 }) ?? true else { return false }
            return requestedBook.map({ resolver.resolve(interval.bookID) == $0 }) ?? true
        }
        let selectedIDs = selectedIntervals.map { Set($0.map(\.id)) }
        let measured = credited.filter { selectedIDs?.contains($0.id) ?? true }
        let seconds = measured.reduce(0) { $0 + $1.duration }
        guard seconds > 0 else { return nil }
        let observedPages = qualified(events: events, effectiveIntervals: credited, merges: merges,
                                      from: nil, through: nil, bookID: bookID, sessionID: sessionID, includeManual: false, selectedIntervals: measured)
            .reduce(0) { $0 + $1.pages }
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

    /// Visibility callers must resolve novelty before clipping to presentation groups.
    /// Compute once for the complete group collection to keep large histories linearithmic.
    static func eventsWithNewPages(events: [AuditEvent], effectiveIntervals: [ReadingInterval], merges: [BookMerge]) -> [AuditEvent] {
        qualified(events: events, effectiveIntervals: effectiveIntervals, merges: merges,
                  from: nil, through: nil, bookID: nil, sessionID: nil)
            .filter { $0.pages > 0 }.map(\.event)
    }

    private struct QualifiedPageTurn {
        var event: AuditEvent
        var pages: Int
    }

    private static func qualified(events: [AuditEvent], effectiveIntervals: [ReadingInterval], merges: [BookMerge],
                                  from: Date?, through: Date?, bookID: String?, sessionID: String?, includeManual: Bool = true, selectedIntervals: [ReadingInterval]? = nil) -> [QualifiedPageTurn] {
        let resolver = MergeResolver(merges: merges)
        let requestedBook = bookID.map(resolver.resolve)
        let intervals = PageIntervalIndex(intervals: effectiveIntervals, resolve: resolver.resolve)
        let selected = selectedIntervals.map { PageIntervalIndex(intervals: $0, resolve: resolver.resolve) }
        var coverage = ReadingCoverage()
        return events.enumerated().sorted {
            $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date
        }.compactMap { _, event in
            guard event.completion == nil, event.rating == nil else { return nil }
            let count: Int
            if event.kind == "pageTurn", let evidence = event.pageTurn, PageTurnTracker.valid(evidence), event.pageAdjustment == nil {
                count = evidence.pagesRead
            } else if includeManual, event.kind == "manualPageAdjustment", let adjustment = event.pageAdjustment,
                      adjustment.isValid(for: event.date), event.pageTurn == nil {
                count = adjustment.pages
            } else { return nil }
            guard let eventBook = event.bookID, let eventSession = event.sessionID,
                  sessionID.map({ eventSession == $0 }) ?? true else { return nil }
            let resolvedBook = resolver.resolve(eventBook)
            guard requestedBook.map({ resolvedBook == $0 }) ?? true else { return nil }
            // Event dates are recorded at checkpoint end boundaries. `contains`
            // is start-exclusive so excluding the fragment that ended at an
            // event cannot retain it through the next fragment's start.
            guard intervals.contains(bookID: resolvedBook, sessionID: eventSession, date: event.date) else { return nil }
            // Resolve coverage before date filtering: a range query cannot make an
            // earlier traversal disappear and credit the same content again.
            let novel = event.pageTurn.map { coverage.pages($0, bookID: resolvedBook, sessionID: eventSession) } ?? count
            guard from.map({ event.date >= $0 }) ?? true, through.map({ event.date < $0 }) ?? true,
                  selected?.contains(bookID: resolvedBook, sessionID: eventSession, date: event.date) ?? true else { return nil }
            return QualifiedPageTurn(event: event, pages: novel)
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

/// Start-exclusive/end-inclusive interval membership, partitioned before searching.
/// Prefix maximum ends also handle overlapping inputs without changing `contains` semantics.
private struct PageIntervalIndex {
    private struct Key: Hashable { let bookID: String; let sessionID: String }
    private struct Bounds { let starts: [Date]; let maximumEnds: [Date] }
    private var groups: [Key: Bounds] = [:]

    init(intervals: [ReadingInterval], resolve: (String) -> String) {
        let grouped = Dictionary(grouping: intervals.filter { $0.disposition != .excluded }) {
            Key(bookID: resolve($0.bookID), sessionID: $0.sessionID)
        }
        for (key, values) in grouped {
            let ordered = values.sorted { $0.start < $1.start }
            var end = Date.distantPast
            let maximumEnds = ordered.map { interval -> Date in
                end = max(end, interval.end)
                return end
            }
            groups[key] = Bounds(starts: ordered.map(\.start), maximumEnds: maximumEnds)
        }
    }

    func contains(bookID: String, sessionID: String, date: Date) -> Bool {
        guard let bounds = groups[Key(bookID: bookID, sessionID: sessionID)] else { return false }
        var lower = 0, upper = bounds.starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if bounds.starts[middle] < date { lower = middle + 1 } else { upper = middle }
        }
        return lower > 0 && bounds.maximumEnds[lower - 1] >= date
    }
}

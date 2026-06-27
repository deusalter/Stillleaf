import Foundation

/// A presentation-only reading session. Its elapsed totals are sums of the
/// recorded intervals; breaks between intervals are never credited.
public struct ReadingSessionGroup: Identifiable, Equatable {
    public var id: String
    public var bookID: String
    public var start: Date
    public var end: Date
    public var intervals: [ReadingInterval]
    public var creditedSeconds: Double
    public var uncertainSeconds: Double

    public init(id: String, bookID: String, start: Date, end: Date,
                intervals: [ReadingInterval], creditedSeconds: Double,
                uncertainSeconds: Double) {
        self.id = id
        self.bookID = bookID
        self.start = start
        self.end = end
        self.intervals = intervals
        self.creditedSeconds = creditedSeconds
        self.uncertainSeconds = uncertainSeconds
    }
}

public enum ReadingSessionGrouping {
    /// Groups checkpoint fragments and short automatic interruptions for
    /// display. Excluded intervals remain barriers, and callers can preserve
    /// deliberate user splits by naming the first interval after each split.
    public static func groups(intervals: [ReadingInterval], merges: [BookMerge],
                              maximumBreak: TimeInterval = 1_200,
                              breakBeforeIntervalIDs: Set<String> = []) -> [ReadingSessionGroup] {
        let resolver = MergeResolver(merges: merges)
        let limit = maximumBreak.isFinite ? max(0, maximumBreak) : 1_200
        let ordered = intervals.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.id < rhs.id
        }
        var result: [ReadingSessionGroup] = []
        var current: ReadingSessionGroup?

        func finish() {
            if let current { result.append(current) }
            current = nil
        }

        for interval in ordered {
            // An excluded interval is omitted from normal history but still
            // separates visible activity on either side of it.
            guard interval.disposition != .excluded else {
                finish()
                continue
            }
            let resolvedBookID = resolver.resolve(interval.bookID)
            if var group = current,
               !breakBeforeIntervalIDs.contains(interval.id),
               canAppend(interval, resolvedBookID: resolvedBookID, to: group, maximumBreak: limit) {
                group.intervals.append(interval)
                group.end = max(group.end, interval.end)
                if interval.disposition == .credited { group.creditedSeconds += interval.duration }
                else if interval.disposition == .uncertain { group.uncertainSeconds += interval.duration }
                current = group
            } else {
                finish()
                current = ReadingSessionGroup(id: interval.id, bookID: resolvedBookID,
                    start: interval.start, end: interval.end, intervals: [interval],
                    creditedSeconds: interval.disposition == .credited ? interval.duration : 0,
                    uncertainSeconds: interval.disposition == .uncertain ? interval.duration : 0)
            }
        }
        finish()
        return result
    }

    /// Hide brief automatic noise only after grouping. This is presentation-only:
    /// evidence, daily totals, and export remain intact. Two minutes of recorded
    /// time is enough to retain time-only reading even without page observations.
    /// Evaluate the whole group before day clipping so midnight does not turn a
    /// legitimate session into an empty fragment on either day.
    public static func visibleGroups(_ groups: [ReadingSessionGroup], events: [AuditEvent],
                                     merges: [BookMerge], activeSessionID: String? = nil,
                                     correctedIntervalIDs: Set<String> = []) -> [ReadingSessionGroup] {
        groups.filter { group in
            if group.intervals.contains(where: {
                $0.mode != .automatic || $0.sessionID == activeSessionID || correctedIntervalIDs.contains($0.id)
            }) { return true }
            if group.creditedSeconds + group.uncertainSeconds >= 120 { return true }
            return PageStatistics.pages(events: events, effectiveIntervals: group.intervals,
                                        merges: merges, bookID: group.bookID) > 0
        }
    }

    private static func canAppend(_ interval: ReadingInterval, resolvedBookID: String,
                                  to group: ReadingSessionGroup, maximumBreak: TimeInterval) -> Bool {
        guard resolvedBookID == group.bookID, let previous = group.intervals.last,
              interval.mode == previous.mode else { return false }
        let gap = interval.start.timeIntervalSince(previous.end)
        guard gap >= 0 else { return false }
        switch interval.mode {
        case .automatic:
            return gap < maximumBreak
        case .manual:
            return interval.sessionID == previous.sessionID
        case .imported:
            return false
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
}

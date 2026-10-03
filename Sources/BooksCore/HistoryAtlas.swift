import Foundation

/// Presentation-only time evidence for History. Pages intentionally stay in PageStatistics.
public struct AtlasTimeSlice: Identifiable, Equatable {
    public let interval: ReadingInterval
    public let bookID: String
    public let start: Date
    public let end: Date
    public let seconds: Double
    public var id: String { interval.id }
}

public struct AtlasBookTime: Identifiable, Equatable {
    public let bookID: String
    public var creditedSeconds: Double = 0
    public var id: String { bookID }
}

public struct AtlasDay: Identifiable, Equatable {
    public let date: Date
    public let key: String
    public var books: [AtlasBookTime]
    public var id: String { key }
    public var creditedSeconds: Double { books.reduce(0) { $0 + $1.creditedSeconds } }
}

public enum HistoryAtlas {
    struct MergeResolver {
        var targets: [String: String] = [:]
        init(merges: [BookMerge]) {
            var latest: [String: Int] = [:]
            for (index, merge) in merges.enumerated() { latest[merge.sourceID] = index }
            for (index, merge) in merges.enumerated() where latest[merge.sourceID] == index && merge.active {
                targets[merge.sourceID] = merge.targetID
            }
        }
        func resolve(_ id: String) -> String {
            var current = id, visited = Set<String>()
            while let next = targets[current], visited.insert(current).inserted { current = next }
            return current
        }
    }

    /// Half-open clipping uses actual elapsed seconds, including 23/25-hour civil days.
    /// Corrected duration is apportioned by overlap, rather than replaced by wall time.
    public static func slices(intervals: [ReadingInterval], merges: [BookMerge], period: DateInterval) -> [AtlasTimeSlice] {
        let resolver = MergeResolver(merges: merges)
        return intervals.compactMap { interval in
            let start = max(interval.start, period.start), end = min(interval.end, period.end)
            let wall = interval.end.timeIntervalSince(interval.start)
            guard start < end, wall > 0, interval.duration.isFinite, interval.duration > 0 else { return nil }
            return AtlasTimeSlice(interval: interval, bookID: resolver.resolve(interval.bookID),
                start: start, end: end, seconds: interval.duration * end.timeIntervalSince(start) / wall)
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    /// One pass over each overlapping interval, split at calendar midnights. Excluded
    /// records remain inspectable via slices but never color a time chart or a ring.
    public static func days(intervals: [ReadingInterval], merges: [BookMerge], period: DateInterval,
                            timezoneID: String) -> [AtlasDay] {
        days(slices: slices(intervals: intervals, merges: merges, period: period), period: period, timezoneID: timezoneID)
    }

    /// Reuse the period's clipping for summaries, charts and session details.
    public static func days(slices: [AtlasTimeSlice], period: DateInterval, timezoneID: String) -> [AtlasDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        var dates: [Date] = [], ends: [Date] = [], cursor = calendar.startOfDay(for: period.start)
        while cursor < period.end {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else {
                ends.append(period.end); break
            }
            ends.append(next)
            cursor = next
        }
        var bins: [Date: [String: AtlasBookTime]] = [:]
        for slice in slices where slice.interval.disposition != .excluded {
            var start = slice.start
            // Calendar boundaries are shared by every interval. Binary search also
            // handles overlapping/unsorted slices without assuming monotonic ends.
            var low = 0, high = dates.count
            while low < high {
                let middle = low + (high - low) / 2
                if dates[middle] <= start { low = middle + 1 } else { high = middle }
            }
            var index = low - 1
            while start < slice.end, index >= 0, index < dates.count {
                let day = dates[index]
                let end = min(ends[index], slice.end)
                let seconds = slice.seconds * end.timeIntervalSince(start) / slice.end.timeIntervalSince(slice.start)
                var entry = bins[day]?[slice.bookID] ?? AtlasBookTime(bookID: slice.bookID)
                if slice.interval.disposition == .credited { entry.creditedSeconds += seconds }
                bins[day, default: [:]][slice.bookID] = entry
                start = end
                index += 1
            }
        }
        return dates.map { date in
            AtlasDay(date: date, key: ReadingStatistics.dayKey(date, timezoneID: timezoneID),
                books: (bins[date]?.values.map { $0 } ?? []).sorted { $0.bookID < $1.bookID })
        }
    }

    /// Use original edition/session evidence and a half-open selected day. In
    /// particular, never substitute the latest position on a linked Library book.
    public static func audioPosition(in group: ReadingSessionGroup, observations: [ProgressObservation],
                                     during period: DateInterval) -> AudiobookProgress? {
        observations.enumerated().filter { pair in
            let observation = pair.element
            guard observation.audio?.isValid == true, observation.observedAt >= period.start,
                  observation.observedAt < period.end else { return false }
            return group.intervals.contains { interval in
                observation.bookID == interval.bookID &&
                observation.sessionID == (interval.audioSessionID ?? interval.sessionID) &&
                observation.observedAt > interval.start && observation.observedAt <= interval.end
            }
        }.max { left, right in
            left.element.observedAt == right.element.observedAt ? left.offset < right.offset : left.element.observedAt < right.element.observedAt
        }?.element.audio
    }
}

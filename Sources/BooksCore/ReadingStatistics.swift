import Foundation

public enum ReadingStatistics {
    public static func dayKey(_ date: Date, timezoneID: String) -> String {
        let calendar = calendar(timezoneID)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public static func daily(intervals: [ReadingInterval], goals: [GoalChange], timezoneID: String, from: Date, through: Date) -> [DailyTotal] {
        guard through >= from else { return [] }
        let calendar = calendar(timezoneID)
        let first = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: through)
        var latestGoalByDay: [String: Double] = [:]
        for goal in goals { latestGoalByDay[goal.effectiveDay] = goal.minutes }
        let goalDays = latestGoalByDay.keys.sorted()
        var output: [DailyTotal] = []
        var dayStarts: [Date] = []
        var dayStart = first
        var activeGoal = 20.0
        var goalIndex = 0
        while dayStart <= last {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let key = dayKey(dayStart, timezoneID: timezoneID)
            while goalIndex < goalDays.count, goalDays[goalIndex] <= key {
                activeGoal = latestGoalByDay[goalDays[goalIndex]] ?? activeGoal
                goalIndex += 1
            }
            dayStarts.append(dayStart)
            output.append(DailyTotal(day: key, creditedSeconds: 0, manualSeconds: 0, goalMinutes: activeGoal))
            dayStart = nextDay
        }
        guard !dayStarts.isEmpty, let endExclusive = calendar.date(byAdding: .day, value: 1, to: last) else { return output }
        for interval in intervals where interval.disposition != .excluded {
            let boundedStart = max(interval.start, first)
            let boundedEnd = min(interval.end, endExclusive)
            guard boundedEnd > boundedStart || (interval.start == interval.end && interval.start >= first && interval.start < endExclusive) else { continue }
            let wallDuration = interval.end.timeIntervalSince(interval.start)
            // Boundaries are computed once, including DST-length civil days. Locate
            // the first affected bin without constructing calendars or date strings
            // for every interval in a long history.
            var lower = 0, upper = dayStarts.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if dayStarts[middle] <= boundedStart { lower = middle + 1 }
                else { upper = middle }
            }
            var index = max(0, lower - 1)
            repeat {
                let nextDay = index + 1 < dayStarts.count ? dayStarts[index + 1] : endExclusive
                let overlapStart = max(interval.start, dayStarts[index])
                let overlapEnd = min(interval.end, nextDay)
                if overlapEnd > overlapStart || wallDuration == 0 {
                    let share = wallDuration > 0 ? interval.duration * overlapEnd.timeIntervalSince(overlapStart) / wallDuration : interval.duration
                    if interval.disposition == .credited {
                        output[index].creditedSeconds += share
                        if interval.mode == .manual { output[index].manualSeconds += share }
                    }
                }
                index += 1
            } while index < dayStarts.count && dayStarts[index] < boundedEnd
        }
        return output
    }

    public static func streak(days: [DailyTotal], today: String) -> StreakSummary {
        let ordered = days.sorted { $0.day < $1.day }
        var longest = 0
        var run = 0
        for day in ordered {
            if day.qualifies { run += 1; longest = max(longest, run) }
            else { run = 0 }
        }

        guard let todayIndex = ordered.lastIndex(where: { $0.day == today }) else {
            return StreakSummary(current: 0, longest: longest, todayPending: true)
        }
        let todayPending = !ordered[todayIndex].qualifies
        var cursor = todayPending ? todayIndex - 1 : todayIndex
        var current = 0
        while cursor >= 0 && ordered[cursor].qualifies {
            current += 1
            cursor -= 1
        }

        return StreakSummary(current: current, longest: longest, todayPending: todayPending)
    }

    private static func calendar(_ timezoneID: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.locale = Locale(identifier: "en_US_POSIX")
        result.timeZone = TimeZone(identifier: timezoneID) ?? TimeZone(secondsFromGMT: 0)!
        return result
    }
}

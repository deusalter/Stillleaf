import Foundation
import BooksCore

/// Synthetic CPU benchmark of the archive-dependent work formerly in view bodies.
/// This does not measure SwiftUI layout, native animation, or input-to-frame latency.
@main
struct HistoryAtlasBenchmark {
    static func main() async throws {
        let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 100_000
        let books = (0..<100).map { BookRecord(id: "b\($0)", title: "Synthetic book \($0)") }
        let origin = ISO8601DateFormatter().date(from: "2024-01-01T00:00:00Z")!
        var intervals: [ReadingInterval] = [], events: [AuditEvent] = []
        for index in 0..<count {
            let start = origin.addingTimeInterval(Double(index) * 600)
            let interval = ReadingInterval(id: "i\(index)", sessionID: "s\(index / 10)", bookID: books[(index / 10) % books.count].id,
                start: start, end: start.addingTimeInterval(60), duration: 60,
                timezoneID: "UTC", mode: .automatic)
            intervals.append(interval)
            events.append(AuditEvent(id: "e\(index)", date: interval.end, kind: "pageTurn", bookID: interval.bookID,
                sessionID: interval.sessionID, detail: "Synthetic benchmark", pageTurn: PageTurnEvidence(fromPage: index + 1,
                    toPage: index + 2, pagesRead: 1, visiblePages: 1, layoutSignature: "fixture")))
        }
        let pageEvidence = PageStatistics.snapshot(events: events, effectiveIntervals: intervals, merges: [])
        let started = ProcessInfo.processInfo.systemUptime
        let source = HistoryAtlasSource(books: books, intervals: intervals, events: events, progress: [],
            merges: [], finishedBooks: [], pageEvidence: pageEvidence)
        print("fixture: \(count) intervals, \(count) page events, \(books.count) books; source preparation \(ms(started)) ms")
        let anchor = intervals.last!.start.addingTimeInterval(-86400)
        var checksum = 0.0
        for scale in CalendarScale.allCases {
            let navigation = CalendarNavigation(timezoneID: "America/Los_Angeles", anchor: anchor, scale: scale)
            let cache = HistoryAtlasCache()
            let legacy = timed(5) { legacyQuery(source: source, navigation: navigation) }
            let cold = timed(5) { consume(HistoryAtlasPeriod(source: source, navigation: navigation)) }
            let prepared = try await cache.presentation(source: source, navigation: navigation)
            var warm: [Double] = []
            for _ in 0..<50 {
                let start = ProcessInfo.processInfo.systemUptime
                let value = try await cache.presentation(source: source, navigation: navigation)
                checksum += consume(value)
                warm.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            let read = timed(50) { consume(prepared) }
            precondition(abs(legacy.checksum / 5 - cold.checksum / 5) < 0.01, "Presentation totals changed")
            checksum += legacy.checksum + cold.checksum + read.checksum
            print("\(scale.rawValue): legacy \(format(legacy.median)) ms; cold prepared \(format(cold.median)) ms (off-main); warm cache \(format(median(warm))) ms; prepared read \(format(read.median)) ms")
        }
        print("checksum: \(checksum)")
    }

    static func consume(_ value: HistoryAtlasPeriod) -> Double {
        Double(value.pages) + value.creditedSeconds
            + Double(value.yearRows.reduce(0) { $0 + $1.activity.count })
    }

    static func legacyQuery(source: HistoryAtlasSource, navigation: CalendarNavigation) -> Double {
        let period = navigation.period
        let days = legacyDays(source: source, period: period, timezoneID: navigation.timezoneID)
        let pages = source.pageEvidence.pages(from: period.start, through: period.end)
        let seconds = days.reduce(0) { $0 + $1.creditedSeconds }
        switch navigation.scale {
        case .day:
            _ = HistoryAtlas.slices(intervals: source.intervals, merges: source.merges, period: period)
            _ = HistoryAtlas.slices(intervals: source.displayIntervals, merges: source.merges, period: period)
            for group in source.sessions where group.end > period.start && group.start < period.end {
                _ = HistoryAtlas.slices(intervals: group.intervals, merges: source.merges, period: period)
                _ = source.pageEvidence.pages(from: period.start, through: period.end, bookID: group.bookID, within: group.intervals)
                _ = PageStatistics.manualPages(events: source.events, effectiveIntervals: group.intervals,
                    merges: source.merges, from: period.start, through: period.end, bookID: group.bookID)
            }
        case .week:
            for id in Set(days.flatMap { $0.books.filter { $0.creditedSeconds > 0 }.map(\.bookID) }) {
                _ = days.flatMap(\.books).filter { $0.bookID == id }.reduce(0) { $0 + $1.creditedSeconds }
                _ = source.pageEvidence.pages(from: period.start, through: period.end, bookID: id)
            }
        case .month:
            // The existing month panel queries every canonical book for the selected
            // day's detail, not for every cell. Daily grid pages were already cached.
            let start = navigation.calendar.startOfDay(for: navigation.anchor)
            let end = navigation.calendar.date(byAdding: .day, value: 1, to: start)!
            for book in source.booksByID.values {
                _ = source.pageEvidence.pages(from: start, through: end, bookID: book.id)
            }
        case .year:
            var marks = 0
            for id in Set(days.flatMap(\.books).map(\.bookID)) {
                let activity = days.filter { $0.books.contains { $0.bookID == id && $0.creditedSeconds > 0 } }
                _ = days.flatMap(\.books).filter { $0.bookID == id }.reduce(0) { $0 + $1.creditedSeconds }
                _ = source.pageEvidence.pages(from: period.start, through: period.end, bookID: id)
                for day in activity { _ = navigation.calendar.date(byAdding: .day, value: 1, to: day.date) }
                marks += activity.count
            }
            return Double(pages + marks) + seconds
        }
        return Double(pages) + seconds
    }


    private struct LegacyBook {
        let bookID: String
        var creditedSeconds = 0.0
    }
    private struct LegacyDay {
        let date: Date
        let key: String
        let books: [LegacyBook]
        var creditedSeconds: Double { books.reduce(0) { $0 + $1.creditedSeconds } }
    }
    private static func legacyDays(source: HistoryAtlasSource, period: DateInterval, timezoneID: String) -> [LegacyDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        var dates: [Date] = [], cursor = calendar.startOfDay(for: period.start)
        while cursor < period.end {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        var bins: [Date: [String: LegacyBook]] = [:]
        for slice in HistoryAtlas.slices(intervals: source.intervals, merges: source.merges, period: period) where slice.interval.disposition != .excluded {
            var start = slice.start
            while start < slice.end {
                let day = calendar.startOfDay(for: start)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > start else { break }
                let end = min(next, slice.end)
                let seconds = slice.seconds * end.timeIntervalSince(start) / slice.end.timeIntervalSince(slice.start)
                var entry = bins[day]?[slice.bookID] ?? LegacyBook(bookID: slice.bookID)
                if slice.interval.disposition == .credited { entry.creditedSeconds += seconds }
                bins[day, default: [:]][slice.bookID] = entry
                start = end
            }
        }
        return dates.map { date in
            LegacyDay(date: date, key: ReadingStatistics.dayKey(date, timezoneID: timezoneID),
                books: (bins[date]?.values.map { $0 } ?? []).sorted { $0.bookID < $1.bookID })
        }
    }

    static func timed(_ iterations: Int, _ body: () -> Double) -> (median: Double, checksum: Double) {
        var values: [Double] = [], checksum = 0.0
        for _ in 0..<iterations {
            let start = ProcessInfo.processInfo.systemUptime
            checksum += body()
            values.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        return (median(values), checksum)
    }
    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    static func format(_ value: Double) -> String { String(format: "%.3f", value) }
    static func ms(_ start: Double) -> String { format((ProcessInfo.processInfo.systemUptime - start) * 1000) }
}

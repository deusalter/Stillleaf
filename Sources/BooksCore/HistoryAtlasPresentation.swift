import Foundation

/// A committed archive revision. Constructed on the existing history refresh queue,
/// then shared by value with period requests; no live model is read by a worker.
public struct HistoryAtlasSource {
    public let revision: UUID
    public let booksByID: [String: BookRecord]
    public let intervals: [ReadingInterval]
    public let displayIntervals: [ReadingInterval]
    public let sessions: [ReadingSessionGroup]
    public let events: [AuditEvent]
    public let progress: [ProgressObservation]
    public let merges: [BookMerge]
    public let finishedBooks: [FinishedBookEntry]
    public let pageEvidence: PageStatistics.Snapshot

    public init(books: [BookRecord], intervals: [ReadingInterval], events: [AuditEvent],
                progress: [ProgressObservation], merges: [BookMerge], finishedBooks: [FinishedBookEntry],
                pageEvidence: PageStatistics.Snapshot, breakBeforeIntervalIDs: Set<String> = []) {
        revision = UUID()
        booksByID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.intervals = intervals
        self.events = events
        self.progress = progress
        self.merges = merges
        self.finishedBooks = finishedBooks
        self.pageEvidence = pageEvidence
        sessions = ReadingSessionGrouping.groups(intervals: intervals, merges: merges,
            breakBeforeIntervalIDs: breakBeforeIntervalIDs)
        var displayed: [ReadingInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if var previous = displayed.last, previous.sessionID == interval.sessionID,
               previous.bookID == interval.bookID, previous.mode == interval.mode,
               previous.disposition == interval.disposition,
               abs(previous.end.timeIntervalSince(interval.start)) < 0.001 {
                displayed.removeLast()
                previous.id = previous.id.hasPrefix("group:") ? previous.id : "group:" + previous.id
                previous.end = interval.end
                previous.duration += interval.duration
                displayed.append(previous)
            } else { displayed.append(interval) }
        }
        displayIntervals = displayed.sorted { $0.start > $1.start }
    }
}

public struct HistoryAtlasKey: Hashable {
    public let revision: UUID
    public let timezoneID: String
    public let scale: CalendarScale
    public let period: DateInterval
    public let today: String
    public let localeID: String

    public init(source: HistoryAtlasSource, navigation: CalendarNavigation, now: Date = Date(),
                localeID: String = Locale.current.identifier) {
        revision = source.revision
        timezoneID = navigation.timezoneID
        scale = navigation.scale
        period = navigation.period
        today = navigation.dayKey(for: now)
        self.localeID = localeID
    }
}

public struct AtlasSessionPresentation: Identifiable {
    public let session: ReadingSessionGroup
    public let slices: [AtlasTimeSlice]
    public let creditedSeconds: Double
    public let uncertainSeconds: Double
    public let pages: Int
    public let manualPages: Int
    public let listening: Bool
    public let position: AudiobookProgress?
    public var id: String { session.id }
}

public struct AtlasDayPresentation {
    public let day: AtlasDay
    public let pages: Int
    public let pagesByBook: [String: Int]
    public let positionsByBook: [String: AudiobookProgress]
    public let bookIDs: [String]
}

public struct AtlasYearMark {
    public let start: Double
    public let end: Double
}

public struct AtlasYearRow: Identifiable {
    public let id: String
    public let creditedSeconds: Double
    public let pages: Int
    public let activity: [AtlasYearMark]
    public let pending: [Double]
    public let finishes: [Double]
    public let target: Date
}

/// All archive-dependent chart work is done before publishing this value.
public struct HistoryAtlasPeriod {
    public let key: HistoryAtlasKey
    public let booksByID: [String: BookRecord]
    public let days: [AtlasDay]
    public let daysByKey: [String: AtlasDayPresentation]
    public let pages: Int
    public let creditedSeconds: Double
    public let activeDays: Int
    public let secondsByBook: [String: Double]
    public let pagesByBook: [String: Int]
    public let creditedBookIDs: [String]
    public let slices: [AtlasTimeSlice]
    public let displaySlicesByBook: [String: [AtlasTimeSlice]]
    public let displayStart: Date?
    public let dayBookIDs: [String]
    public let sessions: [AtlasSessionPresentation]
    public let yearRows: [AtlasYearRow]
    public let monthPositions: [Double]

    public init(source: HistoryAtlasSource, navigation: CalendarNavigation, now: Date = Date()) {
        key = HistoryAtlasKey(source: source, navigation: navigation, now: now)
        booksByID = source.booksByID
        let period = key.period, calendar = navigation.calendar
        let resolver = HistoryAtlas.MergeResolver(merges: source.merges)
        let slices = HistoryAtlas.slices(intervals: source.intervals, merges: source.merges, period: period)
        self.slices = slices
        let days = HistoryAtlas.days(slices: slices, period: period, timezoneID: key.timezoneID)
        self.days = days
        let totals = source.pageEvidence.atlasTotals(period: period, timezoneID: key.timezoneID)
        pages = totals.pages
        pagesByBook = totals.byBook
        creditedSeconds = days.reduce(0) { $0 + $1.creditedSeconds }
        activeDays = days.filter { $0.creditedSeconds > 0 || (totals.byDay[$0.key] ?? 0) > 0 }.count
        var seconds: [String: Double] = [:]
        for day in days {
            for book in day.books { seconds[book.bookID, default: 0] += book.creditedSeconds }
        }
        secondsByBook = seconds
        let pageBookIDs = totals.byBook.keys.filter { totals.byBook[$0, default: 0] > 0 }
        creditedBookIDs = Array(Set(seconds.keys.filter { seconds[$0, default: 0] > 0 } + pageBookIDs)).sorted()

        // Resolve observation identities only for indexing. Original edition/session
        // identities remain intact for audioPosition's historical evidence checks.
        let needsSessions = navigation.scale == .day || navigation.scale == .month
        let observations = needsSessions ? source.progress.filter { $0.observedAt >= period.start && $0.observedAt < period.end } : []
        let observationsByBook = Dictionary(grouping: observations) { resolver.resolve($0.bookID) }
        let overlappingSessions = needsSessions ? source.sessions.filter { $0.end > period.start && $0.start < period.end } : []
        let intervalsByBook = Dictionary(grouping: overlappingSessions.flatMap(\.intervals)) { resolver.resolve($0.bookID) }
        let canonicalBookIDs = Set(source.booksByID.keys.map { resolver.resolve($0) })
        var dayPresentations: [String: AtlasDayPresentation] = [:]
        for day in days {
            let end = calendar.date(byAdding: .day, value: 1, to: day.date) ?? day.date
            let dayPeriod = DateInterval(start: day.date, end: end)
            let bookPages = totals.byDayBook[day.key] ?? [:]
            let pageIDs = bookPages.keys.filter { bookPages[$0, default: 0] > 0 && canonicalBookIDs.contains($0) }
            let ids = Array(Set(day.books.map(\.bookID) + pageIDs)).sorted()
            var positions: [String: AudiobookProgress] = [:]
            if navigation.scale == .month {
                for id in ids {
                    let group = ReadingSessionGroup(id: id, bookID: id, start: day.date, end: end,
                        intervals: intervalsByBook[id] ?? [], creditedSeconds: 0, uncertainSeconds: 0)
                    positions[id] = HistoryAtlas.audioPosition(in: group,
                        observations: observationsByBook[id] ?? [], during: dayPeriod)
                }
            }
            dayPresentations[day.key] = AtlasDayPresentation(day: day, pages: totals.byDay[day.key] ?? 0,
                pagesByBook: bookPages, positionsByBook: positions, bookIDs: ids)
        }
        daysByKey = dayPresentations

        if navigation.scale == .day {
            let displaySlices = HistoryAtlas.slices(intervals: source.displayIntervals, merges: source.merges, period: period)
            displayStart = displaySlices.map(\.start).min()
            displaySlicesByBook = Dictionary(grouping: displaySlices.filter { $0.interval.disposition != .excluded }, by: \.bookID)
            dayBookIDs = Array(Set(slices.filter { $0.interval.disposition != .excluded }.map(\.bookID) + pageBookIDs)).sorted {
                (source.booksByID[$0]?.title ?? "Unknown book").localizedStandardCompare(source.booksByID[$1]?.title ?? "Unknown book") == .orderedAscending
            }
            let slicesByInterval = Dictionary(slices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let audioIdentities = Set(source.progress.filter { $0.audio != nil }.map { AudioIdentity(bookID: $0.bookID, sessionID: $0.sessionID) })
            sessions = overlappingSessions.sorted { $0.start < $1.start }.map { group in
                let parts = group.intervals.compactMap { slicesByInterval[$0.id] }
                return AtlasSessionPresentation(session: group, slices: parts,
                    creditedSeconds: parts.filter { $0.interval.disposition == .credited }.reduce(0) { $0 + $1.seconds },
                    uncertainSeconds: parts.filter { $0.interval.disposition == .uncertain }.reduce(0) { $0 + $1.seconds },
                    pages: source.pageEvidence.pages(from: period.start, through: period.end, bookID: group.bookID, within: group.intervals),
                    manualPages: source.pageEvidence.pages(from: period.start, through: period.end,
                        bookID: group.bookID, within: group.intervals, manualOnly: true),
                    listening: group.intervals.contains { $0.mode == .listening || $0.audioSessionID != nil || audioIdentities.contains(AudioIdentity(bookID: $0.bookID, sessionID: $0.sessionID)) },
                    position: HistoryAtlas.audioPosition(in: group, observations: observationsByBook[group.bookID] ?? [], during: period))
            }
        } else {
            displaySlicesByBook = [:]; displayStart = nil; dayBookIDs = []; sessions = []
        }

        func fraction(_ date: Date) -> Double { date.timeIntervalSince(period.start) / max(1, period.duration) }
        monthPositions = navigation.scale == .year ? navigation.yearMonths.map(fraction) : []
        if navigation.scale == .year {
            var activity: [String: [AtlasYearMark]] = [:], pending: [String: [Double]] = [:]
            var firstDates: [String: Date] = [:], lastActive: [String: Date] = [:], lastPending: [String: Date] = [:]
            for day in days {
                let end = calendar.date(byAdding: .day, value: 1, to: day.date) ?? day.date
                for book in day.books {
                    firstDates[book.bookID] = min(firstDates[book.bookID] ?? .distantFuture, day.date)
                    if book.creditedSeconds > 0 {
                        activity[book.bookID, default: []].append(AtlasYearMark(start: fraction(day.date), end: fraction(end)))
                        lastActive[book.bookID] = day.date
                    } else if book.uncertainSeconds > 0 { pending[book.bookID, default: []].append(fraction(day.date)) }
                    if book.uncertainSeconds > 0 { lastPending[book.bookID] = day.date }
                }
                // Qualified page evidence can exist without recorded time. Keep
                // its book and active day visible without manufacturing seconds.
                for (id, pages) in totals.byDayBook[day.key] ?? [:] where pages > 0 {
                    firstDates[id] = min(firstDates[id] ?? .distantFuture, day.date)
                    lastActive[id] = day.date
                    if !day.books.contains(where: { $0.bookID == id && $0.creditedSeconds > 0 }) {
                        activity[id, default: []].append(AtlasYearMark(start: fraction(day.date), end: fraction(end)))
                    }
                }
            }
            var finishes: [String: [Date]] = [:]
            for entry in source.finishedBooks {
                guard let date = entry.finishedAt, date >= period.start, date < period.end, date <= now else { continue }
                let id = resolver.resolve(entry.id)
                firstDates[id] = min(firstDates[id] ?? .distantFuture, date)
                finishes[id, default: []].append(date)
            }
            yearRows = firstDates.keys.sorted {
                if firstDates[$0] != firstDates[$1] { return firstDates[$0]! < firstDates[$1]! }
                return (source.booksByID[$0]?.title ?? "Unknown book").localizedStandardCompare(source.booksByID[$1]?.title ?? "Unknown book") == .orderedAscending
            }.map { id in
                AtlasYearRow(id: id, creditedSeconds: seconds[id] ?? 0, pages: totals.byBook[id] ?? 0,
                    activity: activity[id] ?? [], pending: pending[id] ?? [], finishes: (finishes[id] ?? []).map(fraction),
                    target: lastActive[id] ?? lastPending[id] ?? finishes[id]?.first.map { calendar.startOfDay(for: $0) } ?? period.start)
            }
        } else { yearRows = [] }
    }

    private struct AudioIdentity: Hashable { let bookID: String; let sessionID: String? }
}

/// Actor isolation keeps calculation off the main actor. Only eight periods survive
/// per archive revision; cancelled navigation requests cannot populate the cache.
public actor HistoryAtlasCache {
    private var entries: [HistoryAtlasKey: HistoryAtlasPeriod] = [:]
    private var order: [HistoryAtlasKey] = []
    private var revision: UUID?
    public let capacity: Int
    public var count: Int { entries.count }

    public init(capacity: Int = 8) { self.capacity = max(1, capacity) }

    public func presentation(source: HistoryAtlasSource, navigation: CalendarNavigation,
                             now: Date = Date()) throws -> HistoryAtlasPeriod {
        try Task.checkCancellation()
        let key = HistoryAtlasKey(source: source, navigation: navigation, now: now)
        if revision != source.revision {
            entries.removeAll(keepingCapacity: true); order.removeAll(keepingCapacity: true)
            revision = source.revision
        }
        if let cached = entries[key] {
            order.removeAll { $0 == key }; order.append(key)
            return cached
        }
        let prepared = HistoryAtlasPeriod(source: source, navigation: navigation, now: now)
        try Task.checkCancellation()
        entries[key] = prepared; order.append(key)
        while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
        return prepared
    }
}

/// A request token also rejects ABA navigation (day → year → the same day).
public struct HistoryAtlasRequestGate {
    private var generation: UInt64 = 0
    public init() {}
    public mutating func begin() -> UInt64 { generation &+= 1; return generation }
    public func accepts(_ token: UInt64) -> Bool { token == generation }
}

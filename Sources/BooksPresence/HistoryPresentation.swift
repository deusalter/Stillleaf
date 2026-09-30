import Foundation
import BooksCore

/// Immutable presentation computed entirely from one committed archive.
struct HistoryPresentation {
    let atlasSource: HistoryAtlasSource
    let books: [BookRecord]
    let intervals: [ReadingInterval]
    let events: [AuditEvent]
    let bookRatings: [String: Double]
    let bookReviewCache: [String: String]
    let bookReviewDates: [String: Date]
    let progress: [ProgressObservation]
    let merges: [BookMerge]
    let libraryPositions: [String: ProgressObservation]
    let correctedIntervalIDs: Set<String>
    let sessionBreakIDs: Set<String>
    let days: [DailyTotal]
    let today: DailyTotal
    let streak: StreakSummary
    let pageEvidence: PageStatistics.Snapshot
    let pageDays: [DailyPageTotal]
    let pageDaysByKey: [String: DailyPageTotal]
    let todayPages: Int
    let pageStreak: StreakSummary
    let goalHistory: [GoalChange]
    let goalProgressByDay: [String: DailyGoalProgress]
    let dailyGoalStreak: StreakSummary
    let annualBookGoal: Int?
    let annualBooksFinished: Int
    let finishedBooks: [FinishedBookEntry]

    init(archive: HistoryArchive, effectiveIntervals: [ReadingInterval], timezoneID: String, goalMinutes: Double, now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        let goalYear = calendar.component(.year, from: now)
        let books = archive.books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let intervals = effectiveIntervals.sorted { $0.start > $1.start }
        let events = archive.events.sorted { $0.date > $1.date }
        let bookRatings = BookHistory.ratings(events: events)
        var latestReviews: [String: AuditEvent] = [:]
        let bookIDs = Set(books.map(\.id))
        for event in archive.events where event.kind == "bookReviewed" && event.review != nil {
            guard let id = event.bookID, bookIDs.contains(id) else { continue }
            if latestReviews[id].map({ $0.date <= event.date }) ?? true { latestReviews[id] = event }
        }
        let bookReviewCache = latestReviews.compactMapValues { $0.review?.text }
        let bookReviewDates = latestReviews.mapValues(\.date)
        let progress = archive.progress.sorted { $0.observedAt > $1.observedAt }
        let merges = archive.merges
        let libraryPositions = LibraryProgressLabel.latestPositions(books: books, observations: progress, merges: merges)
        let correctedIntervalIDs = Set(archive.corrections.flatMap { $0.replacements.map(\.id) })
        let splitSessions = Set(archive.corrections.flatMap { correction -> [String] in
            guard Set(correction.replacements.map(\.sessionID)).count > 1 else { return [] }
            return correction.replacements.sorted { $0.start < $1.start }.dropFirst().map(\.sessionID)
        })
        let sessionBreakIDs = Set(splitSessions.compactMap { session in
            intervals.filter { $0.sessionID == session }.min { $0.start < $1.start }?.id
        })
        let earliest = min(intervals.map(\.start).min() ?? now, Calendar.current.date(byAdding: .day, value: -365, to: now)!)
        let days = ReadingStatistics.daily(intervals: intervals, goals: archive.goals, timezoneID: timezoneID, from: earliest, through: now)
        let key = ReadingStatistics.dayKey(now, timezoneID: timezoneID)
        let today = days.first { $0.day == key } ?? DailyTotal(day: key, creditedSeconds: 0, uncertainSeconds: 0, manualSeconds: 0, goalMinutes: goalMinutes)
        let streak = ReadingStatistics.streak(days: days, today: key)
        let pageEvidence = PageStatistics.snapshot(events: events, effectiveIntervals: intervals, merges: merges)
        let pageDays = pageEvidence.daily(goals: archive.goals, timezoneID: timezoneID, from: earliest, through: now)
        let pageDaysByKey = Dictionary(uniqueKeysWithValues: pageDays.map { ($0.day, $0) })
        let todayPages = pageDays.first { $0.day == key }?.pages ?? 0
        let pageStreak = PageStatistics.streak(days: pageDays, today: key)
        let goalHistory = archive.goals
        let goalProgressByDay = Dictionary(uniqueKeysWithValues: days.map { day in
            (day.day, ReadingGoals.daily(day: day.day, pages: pageDaysByKey[day.day]?.pages ?? 0,
                creditedSeconds: day.creditedSeconds, goals: archive.goals))
        })
        let dailyGoalStreak = ReadingStatistics.streak(days: days.map { day in
            DailyTotal(day: day.day, creditedSeconds: goalProgressByDay[day.day]?.reached == true ? 60 : 0,
                uncertainSeconds: day.uncertainSeconds, manualSeconds: 0, goalMinutes: 1)
        }, today: key)
        let annualBookGoal = ReadingGoals.annualTarget(year: goalYear, events: archive.events)
        let annualBooksFinished = ReadingGoals.finishedCount(year: goalYear, timezoneID: timezoneID,
            books: books, events: archive.events, merges: merges)
        let finishedBooks = BookHistory.completedBooks(books: books, events: archive.events)
        atlasSource = HistoryAtlasSource(books: books, intervals: intervals, events: events, progress: progress,
            merges: merges, finishedBooks: finishedBooks, pageEvidence: pageEvidence,
            breakBeforeIntervalIDs: sessionBreakIDs)
        self.books = books
        self.intervals = intervals
        self.events = events
        self.bookRatings = bookRatings
        self.bookReviewCache = bookReviewCache
        self.bookReviewDates = bookReviewDates
        self.progress = progress
        self.merges = merges
        self.libraryPositions = libraryPositions
        self.correctedIntervalIDs = correctedIntervalIDs
        self.sessionBreakIDs = sessionBreakIDs
        self.days = days
        self.today = today
        self.streak = streak
        self.pageEvidence = pageEvidence
        self.pageDays = pageDays
        self.pageDaysByKey = pageDaysByKey
        self.todayPages = todayPages
        self.pageStreak = pageStreak
        self.goalHistory = goalHistory
        self.goalProgressByDay = goalProgressByDay
        self.dailyGoalStreak = dailyGoalStreak
        self.annualBookGoal = annualBookGoal
        self.annualBooksFinished = annualBooksFinished
        self.finishedBooks = finishedBooks
    }
}

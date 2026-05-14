import Foundation

public enum ReadingMode: String, Codable, CaseIterable { case automatic, manual, imported }
public enum IntervalDisposition: String, Codable { case credited, uncertain, excluded }
public enum PauseReason: String, Codable { case disabled, background, noReadingWindow, locked, displayAsleep, permissionLost, excludedBook, stopped, captureFailure, recovery, clockDiscontinuity }
public enum TrackerPhase: String, Codable { case paused, reading, uncertain }

public struct BookRecord: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var author: String?
    public var source: String
    public var observedAt: Date
    public var coverPath: String?
    public var coverSource: String?
    public var trackingExcluded: Bool
    public var sharingExcluded: Bool
    public init(id: String, title: String, author: String? = nil, source: String = "manual", observedAt: Date = Date(), coverPath: String? = nil, coverSource: String? = nil, trackingExcluded: Bool = false, sharingExcluded: Bool = false) {
        self.id = id; self.title = title; self.author = author; self.source = source; self.observedAt = observedAt
        self.coverPath = coverPath; self.coverSource = coverSource; self.trackingExcluded = trackingExcluded; self.sharingExcluded = sharingExcluded
    }
}
public struct ProgressObservation: Codable, Identifiable, Equatable {
    public var id: String
    public var bookID: String
    public var observedAt: Date
    public var page: Int?
    public var totalPages: Int?
    public var fraction: Double?
    public var location: String?
    public var source: String
    public var reliable: Bool
    public init(id: String = UUID().uuidString, bookID: String, observedAt: Date = Date(), page: Int? = nil, totalPages: Int? = nil, fraction: Double? = nil, location: String? = nil, source: String, reliable: Bool = false) {
        self.id = id; self.bookID = bookID; self.observedAt = observedAt; self.page = page; self.totalPages = totalPages
        self.fraction = fraction; self.location = location; self.source = source; self.reliable = reliable
    }
}
public struct ReadingInterval: Codable, Identifiable, Equatable {
    public var id: String
    public var sessionID: String
    public var bookID: String
    public var start: Date
    public var end: Date
    public var duration: TimeInterval
    public var timezoneID: String
    public var mode: ReadingMode
    public var disposition: IntervalDisposition
    public init(id: String = UUID().uuidString, sessionID: String, bookID: String, start: Date, end: Date, duration: TimeInterval, timezoneID: String, mode: ReadingMode, disposition: IntervalDisposition = .credited) {
        self.id = id; self.sessionID = sessionID; self.bookID = bookID; self.start = start; self.end = end; self.duration = duration; self.timezoneID = timezoneID; self.mode = mode; self.disposition = disposition
    }
}
public struct GoalChange: Codable, Identifiable, Equatable {
    public var id: String
    public var effectiveDay: String
    public var minutes: Double
    public var pages: Double?
    public var createdAt: Date
    public init(id: String = UUID().uuidString, effectiveDay: String, minutes: Double, pages: Double? = nil, createdAt: Date = Date()) {
        self.id = id; self.effectiveDay = effectiveDay; self.minutes = minutes; self.pages = pages; self.createdAt = createdAt
    }
}
public struct AuditEvent: Codable, Identifiable, Equatable {
    public var id: String
    public var date: Date
    public var kind: String
    public var bookID: String?
    public var sessionID: String?
    public var detail: String
    public var pageTurn: PageTurnEvidence?
    public var completion: BookCompletionEvidence?
    public var rating: BookRatingEvidence?
    public init(id: String = UUID().uuidString, date: Date = Date(), kind: String, bookID: String? = nil, sessionID: String? = nil, detail: String, pageTurn: PageTurnEvidence? = nil, completion: BookCompletionEvidence? = nil, rating: BookRatingEvidence? = nil) {
        self.id = id; self.date = date; self.kind = kind; self.bookID = bookID; self.sessionID = sessionID; self.detail = detail
        self.pageTurn = pageTurn; self.completion = completion; self.rating = rating
    }
}
public struct IntervalCorrection: Codable, Identifiable, Equatable {
    public var id: String
    public var createdAt: Date
    public var originalIDs: [String]
    public var replacements: [ReadingInterval]
    public var reason: String
    public init(id: String = UUID().uuidString, createdAt: Date = Date(), originalIDs: [String], replacements: [ReadingInterval], reason: String) {
        self.id = id; self.createdAt = createdAt; self.originalIDs = originalIDs; self.replacements = replacements; self.reason = reason
    }
}
public struct BookMerge: Codable, Identifiable, Equatable {
    public var id: String
    public var sourceID: String
    public var targetID: String
    public var active: Bool
    public var date: Date
    public init(id: String = UUID().uuidString, sourceID: String, targetID: String, active: Bool = true, date: Date = Date()) {
        self.id = id; self.sourceID = sourceID; self.targetID = targetID; self.active = active; self.date = date
    }
}
public struct HistoryArchive: Codable, Equatable {
    public var version: Int = 1
    public var exportedAt: Date = Date()
    public var books: [BookRecord] = []
    public var intervals: [ReadingInterval] = []
    public var corrections: [IntervalCorrection] = []
    public var goals: [GoalChange] = []
    public var events: [AuditEvent] = []
    public var progress: [ProgressObservation] = []
    public var merges: [BookMerge] = []
    public init() {}
}
public struct TrackingInput {
    public var date: Date
    public var uptime: TimeInterval
    public var book: BookRecord?
    public var mode: ReadingMode
    public var pauseReason: PauseReason?
    public var relevantActivity: Bool
    public var progress: ProgressObservation?
    public init(date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, book: BookRecord? = nil, mode: ReadingMode = .automatic, pauseReason: PauseReason? = nil, relevantActivity: Bool = false, progress: ProgressObservation? = nil) {
        self.date = date; self.uptime = uptime; self.book = book; self.mode = mode; self.pauseReason = pauseReason; self.relevantActivity = relevantActivity; self.progress = progress
    }
}
public struct TrackerSnapshot {
    public var phase: TrackerPhase = .paused
    public var book: BookRecord?
    public var mode: ReadingMode = .automatic
    public var sessionID: String?
    public var sessionSeconds: Double = 0
    public var pauseReason: PauseReason?
    public init() {}
}
public struct DailyTotal: Identifiable {
    public var id: String { day }
    public var day: String
    public var creditedSeconds: Double
    public var uncertainSeconds: Double
    public var manualSeconds: Double
    public var goalMinutes: Double
    public var qualifies: Bool { creditedSeconds >= goalMinutes * 60 }
    public init(day: String, creditedSeconds: Double, uncertainSeconds: Double, manualSeconds: Double, goalMinutes: Double) { self.day = day; self.creditedSeconds = creditedSeconds; self.uncertainSeconds = uncertainSeconds; self.manualSeconds = manualSeconds; self.goalMinutes = goalMinutes }
}
public struct DailyPageTotal: Identifiable, Equatable {
    public var id: String { day }
    public var day: String
    public var pages: Int
    public var goalPages: Double?
    public var qualifies: Bool { goalPages.map { $0.isFinite && $0 > 0 && Double(pages) >= $0 } ?? false }
    public init(day: String, pages: Int, goalPages: Double?) {
        self.day = day; self.pages = pages; self.goalPages = goalPages
    }
}
public struct StreakSummary {
    public var current: Int
    public var longest: Int
    public var todayPending: Bool
    public var provisional: Bool
    public init(current: Int, longest: Int, todayPending: Bool, provisional: Bool) { self.current = current; self.longest = longest; self.todayPending = todayPending; self.provisional = provisional }
}

import Foundation

/// Pages the user says they read, either as a plain count or as a position range.
public enum ManualPages: Equatable {
    case count(Int)
    /// Where the user started and stopped, as bookmark positions: `to - from` pages were turned.
    case range(from: Int, to: Int)

    public var count: Int {
        switch self {
        case let .count(count): return count
        case let .range(from, to): return to - from
        }
    }
}

public enum ManualEntryIssue: Equatable {
    case nothingToLog
    case pagesNotPositive
    case pagesTooMany(limit: Int)
    case pageBeyondTotal(total: Int)
    case durationTooLong
    case inFuture
    /// The proposed time overlaps reading already recorded between these dates.
    case overlaps(start: Date, end: Date)
}

public struct ManualEntryRecords: Equatable {
    public var interval: ReadingInterval
    public var events: [AuditEvent]
    public var progress: ProgressObservation?
}

/// One thing the user typed into "Add reading time": minutes, pages, or both, for one book.
/// Pages without minutes are stored on a one-second marker interval that credits no time,
/// so they can sit inside other sessions without ever counting towards a time goal.
public struct ManualReadingEntry: Equatable {
    public static let markerSpan: TimeInterval = 1
    public static let maximumSeconds: TimeInterval = 24 * 3_600

    public var bookID: String
    public var end: Date
    /// Zero means pages only.
    public var seconds: TimeInterval
    public var pages: ManualPages?
    /// The book's last page, when known; bounds a page range.
    public var totalPages: Int?
    public var timezoneID: String
    public var sessionID: String

    public init(bookID: String, end: Date, seconds: TimeInterval, pages: ManualPages? = nil, totalPages: Int? = nil,
                timezoneID: String, sessionID: String = UUID().uuidString) {
        self.bookID = bookID; self.end = end; self.seconds = seconds; self.pages = pages
        self.totalPages = totalPages; self.timezoneID = timezoneID; self.sessionID = sessionID
    }

    public var isPagesOnly: Bool { seconds <= 0 && pages != nil }
    public var start: Date { end.addingTimeInterval(-(seconds > 0 ? seconds : Self.markerSpan)) }

    /// The first reason this entry cannot be saved, or nil. `existing` is the effective history.
    public func issue(existing: [ReadingInterval], now: Date = Date()) -> ManualEntryIssue? {
        guard seconds > 0 || pages != nil else { return .nothingToLog }
        guard seconds.isFinite, seconds <= Self.maximumSeconds else { return .durationTooLong }
        guard end <= now.addingTimeInterval(1) else { return .inFuture }
        if let pages {
            switch pages {
            case let .count(count): guard count > 0 else { return .pagesNotPositive }
            case let .range(from, to): guard from >= 0, to > from else { return .pagesNotPositive }
            }
            let limit = ReadingGoalLimits.dailyPages.upperBound
            guard pages.count <= limit else { return .pagesTooMany(limit: limit) }
            if let totalPages, totalPages > 0 {
                let last: Int
                switch pages {
                case let .count(count): last = count
                case let .range(_, to): last = to
                }
                guard last <= totalPages else { return .pageBeyondTotal(total: totalPages) }
            }
        }
        if seconds > 0, let clash = existing.first(where: {
            $0.disposition != .excluded && $0.duration > 0 && $0.end > start && $0.start < end
        }) { return .overlaps(start: clash.start, end: clash.end) }
        return nil
    }

    /// Everything the store needs to save this entry. Call only for an entry with no issue.
    public func records(now: Date = Date()) -> ManualEntryRecords {
        let interval = ReadingInterval(sessionID: sessionID, bookID: bookID, start: start, end: end,
                                       duration: max(0, seconds), timezoneID: timezoneID, mode: .manual)
        var events: [AuditEvent] = []
        if seconds > 0 {
            events.append(AuditEvent(date: now, kind: "manualAddition", bookID: bookID, sessionID: sessionID,
                                     detail: "User-entered reading time; elapsed duration supplied manually."))
        }
        var progress: ProgressObservation?
        if let pages {
            var from: Int?, to: Int?
            if case let .range(rangeFrom, rangeTo) = pages { from = rangeFrom; to = rangeTo }
            events.append(AuditEvent(date: end, kind: "manualPageAdjustment", bookID: bookID, sessionID: sessionID,
                detail: "User logged \(pages.count) \(pages.count == 1 ? "page" : "pages") manually.",
                pageAdjustment: ManualPageAdjustmentEvidence(pages: pages.count, recordedAt: max(now, end),
                    reason: "Pages logged manually", fromPage: from, toPage: to)))
            if let to {
                let total = totalPages.flatMap { $0 >= to ? $0 : nil }
                progress = ProgressObservation(bookID: bookID, observedAt: end, page: to, totalPages: total,
                    fraction: total.map { Double(to) / Double($0) }, source: "manual-pages", reliable: true, sessionID: sessionID)
            }
        }
        return ManualEntryRecords(interval: interval, events: events, progress: progress)
    }
}

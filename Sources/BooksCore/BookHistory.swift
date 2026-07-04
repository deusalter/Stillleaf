import Foundation

public struct BookCompletionEvidence: Codable, Equatable {
    public var finishedAt: Date?
    public var source: String
    public var imported: Bool
    public init(finishedAt: Date?, source: String, imported: Bool) {
        self.finishedAt = finishedAt; self.source = source; self.imported = imported
    }
}

public struct BookRatingEvidence: Codable, Equatable {
    /// `nil` is an explicit clear operation when carried by a `bookRated` event.
    public var value: Double?
    public init(value: Double?) { self.value = value }
}

public struct AnnualGoalEvidence: Codable, Equatable {
    public var year: Int
    /// `nil` explicitly disables the goal for this year.
    public var books: Int?
    public init(year: Int, books: Int?) { self.year = year; self.books = books }
}

public struct BookReviewEvidence: Codable, Equatable {
    /// `nil` is an explicit clear operation when carried by a `bookReviewed` event.
    public var text: String?
    public init(text: String?) { self.text = text }
}

public struct FinishedBookEntry: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var author: String?
    public var finishedAt: Date?
    public var source: String
    public var imported: Bool
    public init(id: String, title: String, author: String? = nil, finishedAt: Date? = nil,
                source: String, imported: Bool) {
        self.id = id; self.title = title; self.author = author; self.finishedAt = finishedAt
        self.source = source; self.imported = imported
    }
}

public enum BookHistory {
    /// Manual completion evidence is an explicit user override and therefore
    /// remains authoritative over later catalog imports. Within either source
    /// class, the latest observed event wins; array order resolves equal dates.
    public static func completedBooks(books: [BookRecord], events: [AuditEvent]) -> [FinishedBookEntry] {
        var booksByID: [String: BookRecord] = [:]
        for book in books { booksByID[book.id] = book }
        var candidates: [String: [(index: Int, event: AuditEvent, evidence: BookCompletionEvidence)]] = [:]
        for (index, event) in events.enumerated() {
            guard event.kind == "bookCompleted", let bookID = event.bookID,
                  booksByID[bookID] != nil, let evidence = event.completion else { continue }
            candidates[bookID, default: []].append((index, event, evidence))
        }
        var output: [FinishedBookEntry] = []
        for (bookID, values) in candidates {
            let manual = values.filter { !$0.evidence.imported }
            let chosen = latest(manual.isEmpty ? values : manual)
            guard let chosen, let book = booksByID[bookID] else { continue }
            output.append(FinishedBookEntry(id: bookID, title: book.title, author: book.author,
                                            finishedAt: chosen.evidence.finishedAt, source: chosen.evidence.source,
                                            imported: chosen.evidence.imported))
        }
        return output.sorted { lhs, rhs in
            switch (lhs.finishedAt, rhs.finishedAt) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
        }
    }

    /// Returns the latest explicit rating value. A latest typed clear event
    /// intentionally returns nil rather than exposing an older rating.
    public static func rating(bookID: String, events: [AuditEvent]) -> Double? {
        let candidates = events.enumerated().compactMap { index, event -> (index: Int, event: AuditEvent)? in
            guard event.kind == "bookRated", event.bookID == bookID, event.rating != nil else { return nil }
            return (index, event)
        }
        guard let chosen = candidates.max(by: { lhs, rhs in
            lhs.event.date == rhs.event.date ? lhs.index < rhs.index : lhs.event.date < rhs.event.date
        }) else { return nil }
        return chosen.event.rating?.value
    }

    /// Returns the latest explicit review text. A latest typed clear event
    /// intentionally returns nil rather than exposing an older review.
    public static func review(bookID: String, events: [AuditEvent]) -> String? {
        let candidates = events.enumerated().compactMap { index, event -> (index: Int, event: AuditEvent)? in
            guard event.kind == "bookReviewed", event.bookID == bookID, event.review != nil else { return nil }
            return (index, event)
        }
        guard let chosen = candidates.max(by: { lhs, rhs in
            lhs.event.date == rhs.event.date ? lhs.index < rhs.index : lhs.event.date < rhs.event.date
        }) else { return nil }
        return chosen.event.review?.text
    }

    private static func latest(_ values: [(index: Int, event: AuditEvent, evidence: BookCompletionEvidence)])
        -> (index: Int, event: AuditEvent, evidence: BookCompletionEvidence)? {
        values.max { lhs, rhs in
            lhs.event.date == rhs.event.date ? lhs.index < rhs.index : lhs.event.date < rhs.event.date
        }
    }
}

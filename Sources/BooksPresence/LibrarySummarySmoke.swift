import Foundation
import BooksCore

private enum LibrarySummarySmokeError: Error { case mismatch(String) }

/// Verify linked editions, unknown completion dates, and unmerges keep the same
/// shelf semantics when derived metadata moves out of SwiftUI's render path.
func checkLibraryHistorySummary() throws {
    let books = ["a", "b", "c", "d", "e"].map { BookRecord(id: $0, title: $0) }
    let intervals = [("a", 100.0), ("b", 300.0), ("c", 200.0), ("d", 400.0)].map { id, end in
        ReadingInterval(sessionID: id, bookID: id, start: Date(timeIntervalSince1970: end - 10),
                        end: Date(timeIntervalSince1970: end), duration: 10, timezoneID: "UTC", mode: .manual)
    }
    let finished = [
        FinishedBookEntry(id: "a", title: "a", finishedAt: Date(timeIntervalSince1970: 100), source: "Fixture", imported: false),
        FinishedBookEntry(id: "b", title: "b", finishedAt: Date(timeIntervalSince1970: 200), source: "Fixture", imported: false),
        FinishedBookEntry(id: "e", title: "e", source: "Fixture", imported: false)
    ]
    var merges = [BookMerge(sourceID: "a", targetID: "b"), BookMerge(sourceID: "b", targetID: "c")]
    let linked = LibraryHistorySummary(books: books, intervals: intervals, finishedBooks: finished, merges: merges)
    guard linked.books.map(\.id) == ["c", "d", "e"], linked.finishedIDs == Set(["c", "e"]),
          linked.finishedCount == 2, linked.readingCount == 1,
          linked.recent["c"] == Date(timeIntervalSince1970: 300),
          linked.finishes["c"] == Date(timeIntervalSince1970: 200), linked.finishes["e"] == nil else {
        throw LibrarySummarySmokeError.mismatch("Prepared library summary lost linked dates or undated finished books")
    }
    merges.append(BookMerge(sourceID: "b", targetID: "c", active: false))
    let unlinked = LibraryHistorySummary(books: books, intervals: intervals, finishedBooks: finished, merges: merges)
    guard unlinked.books.map(\.id) == ["b", "c", "d", "e"], unlinked.finishedIDs == Set(["b", "e"]),
          unlinked.finishedCount == 2, unlinked.readingCount == 2,
          unlinked.recent["b"] == Date(timeIntervalSince1970: 300),
          unlinked.recent["c"] == Date(timeIntervalSince1970: 200), unlinked.finishes["c"] == nil else {
        throw LibrarySummarySmokeError.mismatch("Prepared library summary retained stale merged metadata after unlinking")
    }
    print("ui-smoke: prepared Library shelves preserve linked editions, dates and unmerges")
}

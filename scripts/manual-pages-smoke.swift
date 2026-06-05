import Foundation
import BooksCore

enum ManualPagesSmokeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case let .failed(message): return message } }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ManualPagesSmokeFailure.failed(message) }
}

private func turn(date: Date, bookID: String, sessionID: String, pages: Int) -> AuditEvent {
    AuditEvent(date: date, kind: "pageTurn", bookID: bookID, sessionID: sessionID,
               detail: "Synthetic observed pages.",
               pageTurn: PageTurnEvidence(fromPage: 1, toPage: pages + 1, pagesRead: pages,
                                           visiblePages: 1, layoutSignature: "smoke"))
}

private func adjustment(date: Date, bookID: String, sessionID: String, pages: Int, recordedAt: Date) -> AuditEvent {
    AuditEvent(date: date, kind: "manualPageAdjustment", bookID: bookID, sessionID: sessionID,
               detail: "User correction.",
               pageAdjustment: ManualPageAdjustmentEvidence(pages: pages, recordedAt: recordedAt, reason: "User correction"))
}

do {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let interval = ReadingInterval(id: "automatic", sessionID: "session", bookID: "source", start: start,
                                   end: start.addingTimeInterval(60), duration: 60, timezoneID: "UTC", mode: .automatic)
    let observed = turn(date: interval.end, bookID: "source", sessionID: "session", pages: 3)
    let corrected = adjustment(date: interval.end, bookID: "source", sessionID: "session", pages: 7,
                               recordedAt: interval.end.addingTimeInterval(60))
    let merges = [BookMerge(sourceID: "source", targetID: "target")]
    let events = [observed, corrected]

    try require(PageStatistics.pages(events: events, effectiveIntervals: [interval], merges: merges, bookID: "target") == 10,
                "manual correction did not add to merged-book pages")
    try require(PageStatistics.manualPages(events: events, effectiveIntervals: [interval], merges: merges, sessionID: "session") == 7,
                "manual correction was not separately counted")
    try require(PageStatistics.pagesPerMinute(events: events, effectiveIntervals: [interval], merges: merges, bookID: "target") == 3,
                "manual correction changed automatic reading pace")
    try require(PageStatistics.pages(events: events, effectiveIntervals: [], merges: merges) == 0,
                "page correction survived deletion of its source interval")
    print("manual-pages-smoke: passed")
} catch {
    fputs("manual-pages-smoke: \(error)\n", stderr)
    exit(1)
}

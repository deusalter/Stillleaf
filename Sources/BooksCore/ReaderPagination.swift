import Foundation

/// Keeps the last observed total only while samples describe the same current
/// reader layout. Books can omit the total when its controls disappear.
public struct ReaderPagination {
    private struct Sample {
        var bookID: String
        var sessionID: String
        var position: ReaderPagePosition
        var uptime: TimeInterval
    }
    private var previous: Sample?
    public init() {}
    public mutating func reset() { previous = nil }

    public mutating func observe(bookID: String, sessionID: String, position: ReaderPagePosition,
                                 uptime: TimeInterval) -> ReaderPagePosition? {
        guard PageTurnTracker.valid(position), !bookID.isEmpty, !sessionID.isEmpty,
              uptime.isFinite, uptime >= 0 else { reset(); return nil }
        var resolved = position
        if position.totalPages == nil, let previous,
           previous.bookID == bookID, previous.sessionID == sessionID,
           previous.position.layoutSignature == position.layoutSignature,
           previous.position.visiblePages == position.visiblePages,
           uptime >= previous.uptime, uptime - previous.uptime <= 5,
           let total = previous.position.totalPages, position.page <= total {
            resolved.totalPages = total
        }
        previous = Sample(bookID: bookID, sessionID: sessionID, position: resolved, uptime: uptime)
        return resolved
    }
}

import Foundation

/// Renderer-owned coordinates for one chapter. Chapter screen pages must never
/// be published as whole-book pages or as a whole-book completion fraction.
public struct NativeReaderPosition: Codable, Equatable {
    public var href: String
    public var page: Int
    public var totalPages: Int
    public var visiblePages: Int
    public var bookOffset: Int?
    public var bookTotal: Int?
    public var lower: Int?
    public var upper: Int?

    public func isValid(spine: [String]) -> Bool {
        spine.contains(href) && page > 0 && page <= totalPages && totalPages <= 10_000_000
            && (1...2).contains(visiblePages)
            && ((bookOffset == nil && bookTotal == nil) ||
                (bookOffset.map { $0 >= 0 && $0 <= (bookTotal ?? -1) } == true &&
                 bookTotal.map { $0 > 0 && $0 <= 268_435_456 } == true))
            && ((lower == nil && upper == nil) || content?.isValid == true)
    }
    public var content: ReaderContentCoverage? {
        guard let lower, let upper else { return nil }
        return ReaderContentCoverage(resource: href, lower: lower, upper: upper)
    }
    public func observation(bookID: String, spine: [String], date: Date = Date()) -> ProgressObservation? {
        guard isValid(spine: spine), let chapter = spine.firstIndex(of: href) else { return nil }
        return ProgressObservation(bookID: bookID, observedAt: date,
            fraction: bookOffset.flatMap { offset in bookTotal.map { Double(offset) / Double($0) } },
            location: "Chapter \(chapter + 1) of \(spine.count) · Page \(page) of \(totalPages)",
            source: "stillleaf-epub-location", reliable: true)
    }
    public func forwardCoverage(spine: [String]) -> PageTurnEvidence? {
        guard isValid(spine: spine), let content else { return nil }
        let pages = min(visiblePages, totalPages - page + 1)
        return PageTurnEvidence(fromPage: page, toPage: page + pages, pagesRead: pages,
                                visiblePages: visiblePages, layoutSignature: "stillleaf-content-v1", content: content)
    }
}

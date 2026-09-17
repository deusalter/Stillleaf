import Foundation

/// UTF-16 text offsets in a sanitized EPUB chapter. Independent of pagination.
/// Coverage means content traversed by sequential navigation, never comprehension.
public struct ReaderContentCoverage: Codable, Equatable {
    public var resource: String
    public var lower: Int
    public var upper: Int
    public init(resource: String, lower: Int, upper: Int) {
        self.resource = resource; self.lower = lower; self.upper = upper
    }
    public var isValid: Bool {
        !resource.isEmpty && resource.utf8.count <= 4096 && lower >= 0 && upper > lower && upper <= 100_000_000
    }
}

/// Reconstructed from surviving durable events, rather than an ephemeral or
/// lifetime high-water mark. Pauses preserve the session; a new session may reread.
struct ReadingCoverage {
    private struct Key: Hashable {
        let book: String
        let session: String
        let coordinate: String
    }
    private var ranges: [Key: [Range<Int>]] = [:]
    private var knownTotals: [Key: Int] = [:]
    private var remainders: [Key: Double] = [:]

    mutating func pages(_ evidence: PageTurnEvidence, bookID: String, sessionID: String) -> Int {
        let content = evidence.content
        let base = Key(book: bookID, session: sessionID,
                       coordinate: content.map { "epub-text:" + $0.resource } ?? "external:" + evidence.layoutSignature)
        var key = base
        if content == nil {
            let total = evidence.totalPages ?? knownTotals[base]
            key = Key(book: bookID, session: sessionID,
                      coordinate: base.coordinate + ":" + (total.map(String.init) ?? "unknown"))
            if let total {
                if knownTotals[base] == nil {
                    let unknown = Key(book: bookID, session: sessionID, coordinate: base.coordinate + ":unknown")
                    // Learning a previously hidden footer total is not a new layout.
                    ranges[key] = ranges.removeValue(forKey: unknown) ?? ranges[key]
                }
                knownTotals[base] = total
            }
        }
        let range = content.map { $0.lower..<$0.upper } ?? evidence.fromPage..<evidence.toPage
        let existing = ranges[key] ?? []
        let overlap = existing.reduce(0) { $0 + max(0, min($1.upperBound, range.upperBound) - max($1.lowerBound, range.lowerBound)) }
        let fresh = range.count - overlap
        var merged: [Range<Int>] = []
        for item in (existing + [range]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, item.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, item.upperBound)
            } else { merged.append(item) }
        }
        ranges[key] = merged
        guard content != nil else { return fresh }
        // Partially revisited screens contribute only their uncovered proportion.
        // Carry fractions within a chapter/session instead of rounding each turn up.
        let value = (remainders[key] ?? 0) + Double(evidence.pagesRead) * Double(fresh) / Double(range.count)
        let whole = Int(floor(value + 1e-9))
        remainders[key] = max(0, value - Double(whole))
        return whole
    }
}

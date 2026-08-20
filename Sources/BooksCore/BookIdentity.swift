import Foundation

/// Evidence that two journal books are the same work, used only to *offer* a link the reader
/// confirms. A title alone is never proof of identity, so nothing is merged automatically.
public enum BookIdentity {
    /// Same title after folding case, accents and punctuation, or one title extending the other
    /// (a series suffix, say) when both books name authors, with no conflicting author names.
    public static func sameWork(_ a: BookRecord, _ b: BookRecord) -> Bool {
        func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
        func key(_ text: String) -> String { String(fold(text).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        func names(_ text: String?) -> Set<String> { Set(fold(text ?? "").components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }) }
        let left = key(a.title), right = key(b.title), authorsA = names(a.author), authorsB = names(b.author)
        guard !left.isEmpty, !right.isEmpty, authorsA.isEmpty || authorsB.isEmpty || !authorsA.isDisjoint(with: authorsB) else { return false }
        if left == right { return true }
        let (short, long) = left.count < right.count ? (left, right) : (right, left)
        return short.count >= 8 && long.hasPrefix(short) && !authorsA.isEmpty && !authorsB.isEmpty
    }
}

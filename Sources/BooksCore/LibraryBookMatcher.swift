import Foundation

/// Finds the user's own books for a search box. Every word typed must appear in the title or author.
public enum LibraryBookMatcher {
    public static func matches(query: String, in books: [BookRecord], formats: Set<BookFormat>? = nil, limit: Int = 8) -> [BookRecord] {
        let folded = fold(query)
        let words = folded.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let scored: [(score: Int, book: BookRecord)] = books.compactMap { book in
            if let formats, !formats.contains(book.resolvedFormat) { return nil }
            let title = fold(book.title), haystack = title + " " + fold(book.author ?? "")
            guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
            if title.hasPrefix(folded) { return (0, book) }
            if title.split(separator: " ").contains(where: { $0.hasPrefix(words[0]) }) && words.allSatisfy({ title.contains($0) }) { return (1, book) }
            if words.allSatisfy({ title.contains($0) }) { return (2, book) }
            return (3, book)
        }
        return scored.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score < rhs.score
                : lhs.book.title.localizedStandardCompare(rhs.book.title) == .orderedAscending
        }.prefix(max(0, limit)).map(\.book)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

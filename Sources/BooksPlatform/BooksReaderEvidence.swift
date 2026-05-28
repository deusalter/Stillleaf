import Foundation
import BooksCore

/// A version-scoped fallback for Books 8's Catalyst EPUB reader, which omits AXDocument.
/// Identity still comes from one exact catalog title match; these markers only classify the window.
struct BooksReaderEvidence {
    var booksVersion: String
    var identifier: String?
    var role: String?
    var subrole: String?
    var minimized: Bool
    var modal: Bool
    var webAreaCount: Int
    var visibleReaderWebAreaCount: Int
    var hasLibraryNavigation: Bool
    var inspectionComplete: Bool
    var pageNavigationToken: String?
    var pagePosition: ReaderPagePosition? = nil

    var permitsUniqueTitleMatch: Bool {
        booksVersion == "8.0" && identifier == "SceneWindow"
            && role == "AXWindow" && subrole == "AXStandardWindow"
            && !minimized && !modal && (1...2).contains(webAreaCount)
            && visibleReaderWebAreaCount == webAreaCount
            && !hasLibraryNavigation && inspectionComplete
    }
}

/// Parses the two page-label formats observed in the English Books 8 EPUB
/// reader. Callers must separately prove the element's structural location
/// before requesting its accessibility description.
enum BooksPageNavigationToken {
    static func position(description: String?) -> (page: Int, totalPages: Int?)? {
        guard let description, description.hasPrefix("Page ") else { return nil }
        let remainder = String(description.dropFirst(5))
        let parts = remainder.components(separatedBy: " of ")
        guard parts.count == 1 || parts.count == 2,
              let page = boundedPositiveASCIIInteger(parts[0]) else { return nil }
        if parts.count == 1 { return (page, nil) }
        guard let total = boundedPositiveASCIIInteger(parts[1]), page <= total else { return nil }
        return (page, total)
    }

    static func parse(description: String?) -> String? {
        position(description: description).map { "books8-page:\($0.page)" }
    }

    private static func boundedPositiveASCIIInteger(_ value: String) -> Int? {
        guard !value.isEmpty, value.count <= 9,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let number = Int(value), number > 0, number <= 10_000_000 else { return nil }
        return number
    }
}

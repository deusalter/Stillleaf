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

/// Parses the one page-label format observed in the English Books 8 EPUB
/// reader. Callers must separately prove the element's structural location
/// before requesting its accessibility description.
enum BooksPageNavigationToken {
    static func parse(description: String?) -> String? {
        guard let description, description.hasPrefix("Page ") else { return nil }
        let digits = description.dropFirst(5)
        guard !digits.isEmpty, digits.count <= 9,
              digits.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let page = Int(digits), page > 0 else { return nil }
        return "books8-page:\(page)"
    }
}

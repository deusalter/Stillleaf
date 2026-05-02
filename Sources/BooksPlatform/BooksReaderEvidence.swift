import Foundation

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
    var hasVisibleReaderWebArea: Bool
    var hasLibraryNavigation: Bool
    var inspectionComplete: Bool

    var permitsUniqueTitleMatch: Bool {
        booksVersion == "8.0" && identifier == "SceneWindow"
            && role == "AXWindow" && subrole == "AXStandardWindow"
            && !minimized && !modal && webAreaCount == 1 && hasVisibleReaderWebArea && !hasLibraryNavigation && inspectionComplete
    }
}

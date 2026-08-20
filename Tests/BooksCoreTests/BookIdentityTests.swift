import XCTest
@testable import BooksCore

final class BookIdentityTests: XCTestCase {
    private func book(_ title: String, _ author: String?) -> BookRecord { BookRecord(id: UUID().uuidString, title: title, author: author) }

    func testFoldedTitlesAndReorderedAuthorsMatch() {
        XCTAssertTrue(BookIdentity.sameWork(book("The Tombs of Atuan", "Ursula K. Le Guin"), book("the tombs of atuan", "Guin, Ursula K. Le")))
        XCTAssertTrue(BookIdentity.sameWork(book("Anna Karénina", nil), book("Anna Karenina", "Leo Tolstoy")))
    }
    func testSeriesSuffixNeedsBothAuthors() {
        let base = book("A Wizard of Earthsea", "Ursula K. Le Guin")
        XCTAssertTrue(BookIdentity.sameWork(base, book("A Wizard of Earthsea (The Earthsea Cycle Book 1)", "Le Guin")))
        XCTAssertFalse(BookIdentity.sameWork(book("A Wizard of Earthsea", nil), book("A Wizard of Earthsea (The Earthsea Cycle Book 1)", "Le Guin")))
        XCTAssertFalse(BookIdentity.sameWork(book("Dune", "Frank Herbert"), book("Dune Messiah", "Frank Herbert")), "short titles never match by prefix")
    }
    func testConflictingAuthorsOrTitlesDoNotMatch() {
        XCTAssertFalse(BookIdentity.sameWork(book("Collected Poems", "Sylvia Plath"), book("Collected Poems", "Philip Larkin")))
        XCTAssertFalse(BookIdentity.sameWork(book("Emma", "Jane Austen"), book("Persuasion", "Jane Austen")))
        XCTAssertFalse(BookIdentity.sameWork(book("!!!", nil), book("???", nil)))
    }
}

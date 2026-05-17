import Foundation
import XCTest
@testable import BooksPlatform
import BooksCore

final class PublicCoverResolverTests: XCTestCase {
    private let sourceURL = URL(string: "https://itunes.apple.com/search?media=ebook&entity=ebook&limit=10&term=book")!

    func testMatchesOneExactNormalizedEbookResult() throws {
        let book = BookRecord(id: "local-book", title: "The Left Hand of Darkness", author: "Ursula K. Le Guin")
        let data = fixture(results: [[
            "kind": "ebook",
            "trackName": "The Left-Hand of Darkness",
            "artistName": "Ursula K. Le Guin",
            "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/book.jpg"
        ]])

        let match = try PublicCoverResolver.decodeMatch(book: book, data: data, sourceURL: sourceURL)

        XCTAssertEqual(match?.url, "https://is1-ssl.mzstatic.com/image/thumb/book.jpg")
        XCTAssertEqual(match?.title, "The Left-Hand of Darkness")
        XCTAssertEqual(match?.author, "Ursula K. Le Guin")
        XCTAssertEqual(match?.sourceURL, sourceURL.absoluteString)
    }

    func testFailsClosedForAmbiguousExactEditions() throws {
        let book = BookRecord(id: "local-book", title: "A Book", author: "An Author")
        let data = fixture(results: [
            result(title: "A Book", author: "An Author", artwork: "https://images.example.com/first.jpg"),
            result(title: "A Book", author: "An Author", artwork: "https://images.example.com/second.jpg")
        ])

        XCTAssertNil(try PublicCoverResolver.decodeMatch(book: book, data: data, sourceURL: sourceURL))
    }

    func testRejectsMismatchedMetadataAndUnsafeArtwork() throws {
        let book = BookRecord(id: "local-book", title: "A Book", author: "An Author")
        let mismatch = fixture(results: [result(title: "Another Book", author: "An Author", artwork: "https://images.example.com/cover.jpg")])
        let localArtwork = fixture(results: [result(title: "A Book", author: "An Author", artwork: "file:///Users/me/cover.jpg")])

        XCTAssertNil(try PublicCoverResolver.decodeMatch(book: book, data: mismatch, sourceURL: sourceURL))
        XCTAssertNil(try PublicCoverResolver.decodeMatch(book: book, data: localArtwork, sourceURL: sourceURL))
    }

    func testSearchRequestIsBoundedToTenEbooksAndRequiresAuthor() {
        let book = BookRecord(id: "local-book", title: "A Book", author: "An Author")
        let request = PublicCoverResolver.request(for: book)
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(request?.url?.scheme, "https")
        XCTAssertEqual(request?.url?.host, "itunes.apple.com")
        XCTAssertEqual(request?.url?.path, "/search")
        XCTAssertEqual(items["media"], "ebook")
        XCTAssertEqual(items["entity"], "ebook")
        XCTAssertEqual(items["limit"], "10")
        XCTAssertEqual(items["term"], "A Book An Author")
        XCTAssertNil(PublicCoverResolver.request(for: BookRecord(id: "local-book", title: "A Book")))
    }

    func testRejectsOversizedResponseBeforeDecoding() {
        let book = BookRecord(id: "local-book", title: "A Book", author: "An Author")
        let oversized = Data(repeating: 0, count: 256 * 1_024 + 1)

        XCTAssertThrowsError(try PublicCoverResolver.decodeMatch(book: book, data: oversized, sourceURL: sourceURL)) { error in
            XCTAssertEqual(error as? PublicCoverResolverError, .responseTooLarge)
        }
    }

    private func fixture(results: [[String: String]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["resultCount": results.count, "results": results])
    }

    private func result(title: String, author: String, artwork: String) -> [String: String] {
        ["kind": "ebook", "trackName": title, "artistName": author, "artworkUrl100": artwork]
    }
}

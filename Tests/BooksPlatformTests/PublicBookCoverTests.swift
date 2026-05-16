import XCTest
@testable import BooksPlatform
import BooksCore

final class PublicBookCoverTests: XCTestCase {
    func testAcceptsPublicHTTPSImageURL() {
        let cover = "https://images.example.com/covers/book.webp"
        XCTAssertEqual(PublicBookCover.assetReference(coverURL: cover, assetKey: "books"), cover)

        let book = BookRecord(id: "book", title: "A Book")
        let payload = try! DiscordActivityPayload.make(book: book, progress: nil, elapsed: 0, applicationID: "123", assetKey: "books", coverURL: cover)
        let activity = ((try! JSONSerialization.jsonObject(with: payload) as! [String: Any])["args"] as! [String: Any])["activity"] as! [String: Any]
        XCTAssertEqual((activity["assets"] as? [String: String])?["large_image"], cover)
    }

    func testRejectsLocalPrivateAndSecretBearingURLs() {
        let rejected = [
            "file:///Users/me/Covers/book.jpg",
            "http://images.example.com/book.jpg",
            "data:image/jpeg;base64,abc",
            "https://localhost/book.jpg",
            "https://127.0.0.1/book.jpg",
            "https://[::1]/book.jpg",
            "https://cover/book.jpg",
            "https://cover.local/book.jpg",
            "https://cover.internal/book.jpg",
            "https://-cover.example/book.jpg",
            "https://cover-.example/book.jpg",
            "https://cover..example/book.jpg",
            "https://reader:secret@images.example.com/book.jpg",
            "https://images.example.com/book.jpg?token=secret",
            "https://images.example.com/book.pdf"
        ]

        for value in rejected { XCTAssertNil(PublicBookCover.publicImageURL(value), value) }
    }

    func testInvalidURLFallsBackOnlyToSafeUploadedAssetKey() throws {
        XCTAssertEqual(
            PublicBookCover.assetReference(coverURL: "file:///Users/me/Covers/book.jpg", assetKey: "books"),
            "books"
        )
        XCTAssertNil(PublicBookCover.assetReference(coverURL: "file:///Users/me/Covers/book.jpg", assetKey: "../cover"))

        let book = BookRecord(id: "book", title: "A Book")
        let payload = try DiscordActivityPayload.make(book: book, progress: nil, elapsed: 0, applicationID: "123", assetKey: "", coverURL: "file:///Users/me/Covers/book.jpg")
        let activity = ((try JSONSerialization.jsonObject(with: payload) as! [String: Any])["args"] as! [String: Any])["activity"] as! [String: Any]

        XCTAssertNil(activity["assets"])
        XCTAssertFalse(String(data: payload, encoding: .utf8)!.contains("file:///"))
    }
}

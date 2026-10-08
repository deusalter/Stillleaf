import Foundation
import XCTest
@testable import BooksPlatform

final class OpenLibrarySearchTests: XCTestCase {
    private struct Stub: BookSearchTransport {
        var handler: @Sendable (URLRequest) throws -> (Data, Int)
        func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, status) = try handler(request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let sample = Data("""
    {"numFound": 3, "docs": [
      {"key": "/works/OL1W", "title": "Piranesi", "author_name": ["Susanna Clarke"], "cover_i": 10, "number_of_pages_median": 272, "first_publish_year": 2020},
      {"key": "/works/OL2W", "title": "  Jonathan Strange & Mr Norrell ", "author_name": ["Susanna Clarke", "Portia Rosenberg", "Third"], "number_of_pages_median": 0},
      {"key": "/books/OL3M", "title": "Not a work"},
      {"key": "/works/OL1W", "title": "Piranesi again"},
      {"key": "/works/OL4W"}
    ]}
    """.utf8)

    func testRequestSendsOnlyTheSearchText() throws {
        let request = try XCTUnwrap(OpenLibraryClient.request(for: "  the   left hand "))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "openlibrary.org")
        XCTAssertEqual(components.path, "/search.json")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["q"], "the left hand")
        XCTAssertEqual(items["limit"], "8")
        XCTAssertEqual(items["fields"], "key,title,author_name,cover_i,number_of_pages_median,first_publish_year")
        XCTAssertEqual(Set(items.keys), ["q", "fields", "limit"])
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(OpenLibraryClient.request(for: " a "))
        XCTAssertNil(OpenLibraryClient.request(for: "   "))
    }

    func testDecodeKeepsWorksAndDropsUnusableRows() throws {
        let books = try OpenLibraryClient.decode(sample)
        XCTAssertEqual(books.map(\.key), ["/works/OL1W", "/works/OL2W"])
        XCTAssertEqual(books[0].author, "Susanna Clarke")
        XCTAssertEqual(books[0].pageCount, 272)
        XCTAssertEqual(books[0].firstPublishYear, 2020)
        XCTAssertEqual(books[0].coverURL?.absoluteString, "https://covers.openlibrary.org/b/id/10-M.jpg")
        XCTAssertEqual(books[0].libraryID, "openlibrary:OL1W")
        XCTAssertEqual(books[1].title, "Jonathan Strange & Mr Norrell")
        XCTAssertEqual(books[1].author, "Susanna Clarke, Portia Rosenberg")
        XCTAssertNil(books[1].pageCount)
        XCTAssertNil(books[1].coverURL)
    }

    func testMalformedAndOversizedResponsesFail() {
        XCTAssertThrowsError(try OpenLibraryClient.decode(Data("not json".utf8))) { XCTAssertEqual($0 as? BookSearchError, .malformed) }
        XCTAssertThrowsError(try OpenLibraryClient.decode(Data(count: 600 * 1_024))) { XCTAssertEqual($0 as? BookSearchError, .tooLarge) }
    }

    func testSearchUsesTheTransportAndSkipsTinyQueries() async throws {
        let client = OpenLibraryClient(transport: Stub { _ in (self.sample, 200) })
        let found = try await client.search("piranesi")
        XCTAssertEqual(found.count, 2)
        let none = try await OpenLibraryClient(transport: Stub { _ in XCTFail("no request expected"); return (Data(), 200) }).search("a")
        XCTAssertTrue(none.isEmpty)
    }

    func testFailuresMapToStableErrors() async {
        func failure(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) async -> BookSearchError? {
            do { _ = try await OpenLibraryClient(transport: Stub(handler: handler)).search("piranesi"); return nil }
            catch { return error as? BookSearchError }
        }
        let offline = await failure { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(offline, .offline)
        let timeout = await failure { _ in throw URLError(.timedOut) }
        XCTAssertEqual(timeout, .timedOut)
        let server = await failure { _ in (Data(), 503) }
        XCTAssertEqual(server, .unavailable(status: 503))
        let garbled = await failure { _ in (Data("<html>".utf8), 200) }
        XCTAssertEqual(garbled, .malformed)
    }

    func testCancelledRequestsSurfaceAsCancellation() async {
        let client = OpenLibraryClient(transport: Stub { _ in throw URLError(.cancelled) })
        do { _ = try await client.search("piranesi"); XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCoverFetchTreatsMissingImagesAsNone() async throws {
        let book = OutsideBook(key: "/works/OL1W", title: "Piranesi", coverID: 10)
        let image = Data([1, 2, 3])
        let found = try await OpenLibraryClient(transport: Stub { _ in (image, 200) }).coverData(for: book)
        XCTAssertEqual(found, image)
        let missing = try await OpenLibraryClient(transport: Stub { _ in (Data(), 404) }).coverData(for: book)
        XCTAssertNil(missing)
        let noCover = try await OpenLibraryClient(transport: Stub { _ in XCTFail("no request expected"); return (Data(), 200) })
            .coverData(for: OutsideBook(key: "/works/OL2W", title: "No cover"))
        XCTAssertNil(noCover)
    }
}

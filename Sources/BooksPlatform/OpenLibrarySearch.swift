import Foundation

/// A book found in a public catalogue rather than in the user's library.
public struct OutsideBook: Equatable, Identifiable, Sendable {
    /// Open Library's work key, such as `/works/OL45883W`.
    public let key: String
    public let title: String
    public let author: String?
    public let coverID: Int?
    public let pageCount: Int?
    public let firstPublishYear: Int?

    public init(key: String, title: String, author: String? = nil, coverID: Int? = nil,
                pageCount: Int? = nil, firstPublishYear: Int? = nil) {
        self.key = key; self.title = title; self.author = author; self.coverID = coverID
        self.pageCount = pageCount; self.firstPublishYear = firstPublishYear
    }

    public var id: String { key }

    /// The identity a saved copy gets in the library, so the same work is never added twice.
    public var libraryID: String { "openlibrary:" + (key.split(separator: "/").last.map(String.init) ?? key) }

    public var coverURL: URL? {
        coverID.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-M.jpg") }
    }
}

public enum BookSearchError: Error, Equatable, Sendable {
    /// No connection, or the host could not be reached.
    case offline
    case timedOut
    case unavailable(status: Int)
    case malformed
    case tooLarge
}

/// Where outside books come from. Tests substitute their own.
public protocol BookSearchService: Sendable {
    func search(_ query: String) async throws -> [OutsideBook]
    /// The cover image bytes, or nil when the book has none.
    func coverData(for book: OutsideBook) async throws -> Data?
}

public protocol BookSearchTransport: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionBookSearchTransport: BookSearchTransport {
    private let session: URLSession

    public init() {
        // Ephemeral and cookie-free: the only thing that leaves the Mac is the request itself.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BookSearchError.malformed }
        return (data, http)
    }
}

/// Searches Open Library (https://openlibrary.org/dev/docs/api/search), which needs no key.
/// Only the text the user typed is sent; no library contents, identifiers or history.
public struct OpenLibraryClient: BookSearchService {
    public static let maximumQueryLength = 120
    static let maximumResponseBytes = 512 * 1_024
    static let maximumCoverBytes = 2 * 1_024 * 1_024
    static let resultLimit = 8

    private let transport: BookSearchTransport

    public init(transport: BookSearchTransport = URLSessionBookSearchTransport()) {
        self.transport = transport
    }

    public func search(_ query: String) async throws -> [OutsideBook] {
        guard let request = Self.request(for: query) else { return [] }
        let data = try await send(request, limit: Self.maximumResponseBytes)
        return try Self.decode(data)
    }

    public func coverData(for book: OutsideBook) async throws -> Data? {
        guard let url = book.coverURL else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        do { return try await send(request, limit: Self.maximumCoverBytes) }
        catch BookSearchError.unavailable(status: 404) { return nil }
    }

    static let userAgent = "Stillleaf (macOS reading tracker; book search)"

    /// Nil for a query too short to be worth a request.
    static func request(for query: String) -> URLRequest? {
        let text = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count >= 2 else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "openlibrary.org"
        components.path = "/search.json"
        components.queryItems = [
            URLQueryItem(name: "q", value: String(text.prefix(maximumQueryLength))),
            URLQueryItem(name: "fields", value: "key,title,author_name,cover_i,number_of_pages_median,first_publish_year"),
            URLQueryItem(name: "limit", value: String(resultLimit))
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        return request
    }

    static func decode(_ data: Data) throws -> [OutsideBook] {
        guard data.count <= maximumResponseBytes else { throw BookSearchError.tooLarge }
        struct Response: Decodable {
            struct Doc: Decodable {
                let key: String?
                let title: String?
                let author_name: [String]?
                let cover_i: Int?
                let number_of_pages_median: Int?
                let first_publish_year: Int?
            }
            let docs: [Doc]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw BookSearchError.malformed }
        var seen = Set<String>()
        return response.docs.prefix(resultLimit).compactMap { doc -> OutsideBook? in
            guard let key = doc.key, key.hasPrefix("/works/"), key.count <= 40,
                  let title = doc.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.count <= 300,
                  seen.insert(key).inserted else { return nil }
            let author = doc.author_name?.prefix(2).joined(separator: ", ")
            return OutsideBook(key: key, title: title, author: author?.isEmpty == false ? author : nil,
                               coverID: doc.cover_i.flatMap { $0 > 0 ? $0 : nil },
                               pageCount: doc.number_of_pages_median.flatMap { (1...100_000).contains($0) ? $0 : nil },
                               firstPublishYear: doc.first_publish_year.flatMap { (1...9999).contains($0) ? $0 : nil })
        }
    }

    private func send(_ request: URLRequest, limit: Int) async throws -> Data {
        do {
            let (data, response) = try await transport.fetch(request)
            guard response.statusCode == 200 else { throw BookSearchError.unavailable(status: response.statusCode) }
            guard data.count <= limit else { throw BookSearchError.tooLarge }
            return data
        } catch let error as BookSearchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw BookSearchError.timedOut
            default: throw BookSearchError.offline
            }
        }
    }
}

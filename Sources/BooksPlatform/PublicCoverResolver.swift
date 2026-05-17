import Foundation
import BooksCore

/// A public cover selected from Apple's iTunes Search API. The image is never
/// downloaded by this app; Discord retrieves `url` when it renders the card.
public struct PublicCoverMatch: Equatable, Sendable {
    public let url: String
    public let title: String
    public let author: String
    public let sourceURL: String

    public init(url: String, title: String, author: String, sourceURL: String) {
        self.url = url
        self.title = title
        self.author = author
        self.sourceURL = sourceURL
    }
}

public enum PublicCoverResolverError: Error, Equatable {
    case invalidResponse
    case responseTooLarge
}

/// Resolves an opt-in public cover through the documented iTunes Search API.
///
/// Apple's API documents `media=ebook`, `entity=ebook`, and a bounded `limit`:
/// https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/Searching.html
/// Results must match both the normalized title and author exactly. A missing or
/// ambiguous result is intentionally treated as no result. `BookRecord` does
/// not expose a verified iBooks Store identifier or ISBN, so this type never
/// tries to infer one from its local `id`.
public actor PublicCoverResolver {
    private static let maximumResults = 10
    private static let maximumResponseBytes = 256 * 1_024
    private static let maximumCacheEntries = 128
    private static let successCacheLifetime: TimeInterval = 24 * 60 * 60
    private static let missCacheLifetime: TimeInterval = 15 * 60

    private struct CacheEntry {
        let value: PublicCoverMatch?
        let expiresAt: Date
    }

    private let session: URLSession
    private let redirectDelegate: NoRedirectSessionDelegate
    private var cache: [String: CacheEntry] = [:]
    private var cacheOrder: [String] = []

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldSetCookies = false
        let delegate = NoRedirectSessionDelegate()
        redirectDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Returns a validated public image URL only when one unique e-book result
    /// has the same normalized title and author as `book`.
    public func resolve(book: BookRecord) async throws -> PublicCoverMatch? {
        guard let request = Self.request(for: book), let key = Self.cacheKey(for: book) else { return nil }
        let now = Date()
        if let entry = cache[key], entry.expiresAt > now { return entry.value }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  Self.isExpectedSearchResponseURL(httpResponse.url) else {
                throw PublicCoverResolverError.invalidResponse
            }
            guard response.expectedContentLength < 0 || response.expectedContentLength <= Int64(Self.maximumResponseBytes),
                  data.count <= Self.maximumResponseBytes else {
                throw PublicCoverResolverError.responseTooLarge
            }

            let value = try Self.decodeMatch(book: book, data: data, sourceURL: request.url!)
            store(value, for: key, now: now)
            return value
        } catch {
            if Task.isCancelled { throw error }
            // A failed lookup gets the same short cooldown as a verified miss,
            // preventing repeated activity updates from retrying a bad network
            // response. The first failure remains observable to the caller.
            store(nil, for: key, now: now)
            throw error
        }
    }

    static func request(for book: BookRecord) -> URLRequest? {
        guard let title = usable(book.title), let author = usable(book.author) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "media", value: "ebook"),
            URLQueryItem(name: "entity", value: "ebook"),
            URLQueryItem(name: "limit", value: String(maximumResults)),
            URLQueryItem(name: "term", value: "\(title) \(author)")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        return request
    }

    static func decodeMatch(book: BookRecord, data: Data, sourceURL: URL) throws -> PublicCoverMatch? {
        guard data.count <= maximumResponseBytes else { throw PublicCoverResolverError.responseTooLarge }
        guard let title = usable(book.title), let author = usable(book.author) else { return nil }
        let response = try JSONDecoder().decode(AppleSearchResponse.self, from: data)
        let wantedTitle = normalized(title)
        let wantedAuthor = normalized(author)
        let exactResults = response.results.prefix(maximumResults).filter { result in
            guard result.kind?.lowercased() == "ebook",
                  let resultTitle = result.trackName,
                  let resultAuthor = result.artistName else { return false }
            return normalized(resultTitle) == wantedTitle && normalized(resultAuthor) == wantedAuthor
        }
        guard exactResults.count == 1,
              let result = exactResults.first,
              let resultTitle = result.trackName,
              let resultAuthor = result.artistName,
              let artworkURL = result.artworkURL,
              let publicURL = PublicBookCover.publicImageURL(artworkURL) else { return nil }
        return PublicCoverMatch(url: publicURL, title: resultTitle, author: resultAuthor, sourceURL: sourceURL.absoluteString)
    }

    private static func usable(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 512 else { return nil }
        return value
    }

    private static func cacheKey(for book: BookRecord) -> String? {
        guard let title = usable(book.title), let author = usable(book.author) else { return nil }
        return "\(normalized(title))\u{1F}|\(normalized(author))"
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func isExpectedSearchResponseURL(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "itunes.apple.com"
            && components.path == "/search"
    }

    private func store(_ value: PublicCoverMatch?, for key: String, now: Date) {
        if cache[key] == nil, cache.count >= Self.maximumCacheEntries, let oldest = cacheOrder.first {
            cache.removeValue(forKey: oldest)
            cacheOrder.removeFirst()
        }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        cache[key] = CacheEntry(
            value: value,
            expiresAt: now.addingTimeInterval(value == nil ? Self.missCacheLifetime : Self.successCacheLifetime)
        )
    }
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct AppleSearchResponse: Decodable {
    let results: [AppleSearchResult]
}

private struct AppleSearchResult: Decodable {
    let kind: String?
    let trackName: String?
    let artistName: String?
    let artworkURL: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case trackName
        case artistName
        case artworkURL = "artworkUrl100"
    }
}

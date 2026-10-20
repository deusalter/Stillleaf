import BooksCore
import Foundation

public protocol UpdateFeedTransport: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// One plain GET of the feed: ephemeral, no cookies, no cache and no redirects, so the request
/// carries nothing but the app version and the network address any web request reveals.
public final class URLSessionUpdateFeedTransport: UpdateFeedTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate = RefuseRedirects()

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateFeedError.unavailable("The update server did not respond.") }
        return (data, http)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct UpdateChecker: Sendable {
    /// Info.plist key holding the feed URL. Release packaging sets it; development builds have
    /// none, so they never contact the network for updates.
    public static let feedURLKey = "StillleafUpdateFeedURL"

    public let feedURL: URL
    public let bundleIdentifier: String
    public let version: String
    public let build: Int
    private let transport: UpdateFeedTransport

    public init(feedURL: URL, bundleIdentifier: String, version: String, build: Int,
                transport: UpdateFeedTransport = URLSessionUpdateFeedTransport()) {
        self.feedURL = feedURL; self.bundleIdentifier = bundleIdentifier
        self.version = version; self.build = build; self.transport = transport
    }

    /// Nil when the bundle has no valid https feed URL, a usable version, or a build number.
    public init?(bundle: Bundle, transport: UpdateFeedTransport = URLSessionUpdateFeedTransport()) {
        guard let value = bundle.object(forInfoDictionaryKey: Self.feedURLKey) as? String,
              let url = URL(string: value), UpdateRelease.isPublicHTTPS(url),
              let identifier = bundle.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) else { return nil }
        self.init(feedURL: url, bundleIdentifier: identifier, version: version, build: build, transport: transport)
    }

    public var request: URLRequest {
        var request = URLRequest(url: feedURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Replaces the default agent, which would also name the CFNetwork and Darwin versions.
        request.setValue("Stillleaf/\(version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    public func check(system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) async throws -> UpdateAvailability {
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.fetch(request) }
        catch let error as UpdateFeedError { throw error }
        catch { throw UpdateFeedError.unavailable("Could not reach the update server. Check your connection and try again.") }
        guard response.statusCode == 200 else { throw UpdateFeedError.unavailable("The update server answered with status \(response.statusCode).") }
        return try UpdateFeed.parse(data, bundleIdentifier: bundleIdentifier).availability(currentBuild: build, system: system)
    }
}

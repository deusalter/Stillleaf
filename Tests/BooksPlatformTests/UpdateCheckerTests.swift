import Foundation
import XCTest
import BooksCore
@testable import BooksPlatform

final class UpdateCheckerTests: XCTestCase {
    private struct Stub: UpdateFeedTransport {
        var handler: @Sendable (URLRequest) throws -> (Data, Int)
        func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, status) = try handler(request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let feedURL = URL(string: "https://stillleaf.invalid/updates/macos.json")!
    private let body = Data("""
    {"schemaVersion": 1, "bundleIdentifier": "com.bookspresence.app", "latest": {"version": "1.6.0", "build": 700,
     "minimumSystemVersion": "13.0", "url": "https://stillleaf.invalid/download/Stillleaf-1.6.0.dmg",
     "sha256": "\(String(repeating: "0f", count: 32))"}}
    """.utf8)
    private let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 5, patchVersion: 0)

    func testRequestCarriesOnlyTheAppVersion() async throws {
        let body = self.body, feedURL = self.feedURL
        let checker = UpdateChecker(feedURL: feedURL, bundleIdentifier: "com.bookspresence.app", version: "1.5.0", build: 612,
                                    transport: Stub { request in
            XCTAssertEqual(request.url, feedURL)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Stillleaf/1.5.0")
            XCTAssertNil(request.httpBody)
            return (body, 200)
        })
        guard case .available(let release) = try await checker.check(system: ventura) else { return XCTFail("expected an update") }
        XCTAssertEqual(release.build, 700)
    }

    func testServerErrorsAreReportedNotParsed() async {
        let body = self.body
        let checker = UpdateChecker(feedURL: feedURL, bundleIdentifier: "com.bookspresence.app", version: "1.5.0", build: 612,
                                    transport: Stub { _ in (body, 404) })
        do { _ = try await checker.check(system: ventura); XCTFail("a 404 is not a feed") }
        catch { XCTAssertEqual(error as? UpdateFeedError, .unavailable("The update server answered with status 404.")) }
    }

    /// The feed the website generates (website/tests/site.test.mjs checks it byte for byte).
    func testParsesTheWebsiteFeedContract() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/update-feed/macos.json")
        let feed = try UpdateFeed.parse(Data(contentsOf: fixture), bundleIdentifier: "com.bookspresence.app")
        XCTAssertEqual(feed.latest.version, "2.0.0")
        XCTAssertEqual(feed.latest.build, 24)
        XCTAssertEqual(feed.latest.minimumSystemVersion, "13.0")
        XCTAssertEqual(feed.latest.size, 18_204_331)
        XCTAssertEqual(feed.latest.url.absoluteString, "https://releases.stillleaf.app/Stillleaf-2.0.0.dmg")
        XCTAssertEqual(feed.latest.pageURL.absoluteString, "https://stillleaf.app/#downloads")
        guard case .available = feed.availability(currentBuild: 23, system: ventura) else { return XCTFail("expected an update") }
    }

    func testDevelopmentBundleHasNoChecker() {
        // Test bundles carry no StillleafUpdateFeedURL, like local development builds.
        XCTAssertNil(UpdateChecker(bundle: Bundle(for: Self.self)))
    }
}

import Foundation
import XCTest
@testable import BooksCore

final class UpdateFeedTests: XCTestCase {
    private let identifier = "com.bookspresence.app"
    private let digest = String(repeating: "ab", count: 32)
    private let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)

    private func feed(build: Int = 700, version: String = "1.6.0", minimum: String = "13.0",
                      url: String = "https://stillleaf.invalid/download/Stillleaf-1.6.0.dmg",
                      notes: String? = nil, schema: Int = 1, app: String? = nil, sha: String? = nil) -> Data {
        var latest: [String: Any] = ["version": version, "build": build, "minimumSystemVersion": minimum,
                                     "url": url, "sha256": sha ?? digest, "size": 1234]
        if let notes { latest["releaseNotesURL"] = notes }
        return try! JSONSerialization.data(withJSONObject: ["schemaVersion": schema, "bundleIdentifier": app ?? identifier, "latest": latest] as [String: Any])
    }

    func testNewerBuildIsOfferedWithItsPage() throws {
        let parsed = try UpdateFeed.parse(feed(notes: "https://stillleaf.invalid/releases/1.6.0"), bundleIdentifier: identifier)
        guard case .available(let release) = parsed.availability(currentBuild: 612, system: ventura) else { return XCTFail("expected an update") }
        XCTAssertEqual(release.version, "1.6.0")
        XCTAssertEqual(release.pageURL.absoluteString, "https://stillleaf.invalid/releases/1.6.0")
    }

    func testSameOrOlderBuildIsUpToDate() throws {
        let parsed = try UpdateFeed.parse(feed(build: 612), bundleIdentifier: identifier)
        XCTAssertEqual(parsed.availability(currentBuild: 612, system: ventura), .upToDate)
        XCTAssertEqual(parsed.availability(currentBuild: 900, system: ventura), .upToDate)
    }

    func testReleaseNeedingNewerMacOSIsNotOffered() throws {
        let parsed = try UpdateFeed.parse(feed(minimum: "14.2"), bundleIdentifier: identifier)
        guard case .requiresNewerSystem = parsed.availability(currentBuild: 612, system: ventura) else { return XCTFail("expected a system requirement") }
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
        guard case .available = parsed.availability(currentBuild: 612, system: sonoma) else { return XCTFail("14.2 satisfies 14.2") }
    }

    func testRejectsUnsafeOrForeignFeeds() {
        let rejected: [Data] = [
            feed(url: "http://stillleaf.invalid/Stillleaf.dmg"),
            feed(url: "https://user:secret@stillleaf.invalid/Stillleaf.dmg"),
            feed(notes: "file:///Applications"),
            feed(schema: 2),
            feed(app: "com.example.other"),
            feed(sha: "not-a-digest"),
            feed(version: "1.6"),
            feed(build: 0),
            feed(minimum: "fourteen"),
            Data("{".utf8),
            Data(count: UpdateFeed.maximumSize + 1),
        ]
        for data in rejected {
            XCTAssertThrowsError(try UpdateFeed.parse(data, bundleIdentifier: identifier))
        }
    }
}

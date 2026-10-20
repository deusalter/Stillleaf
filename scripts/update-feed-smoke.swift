import Foundation
import BooksCore
import BooksPlatform

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let identifier = "com.bookspresence.app"
let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
func feed(build: Int = 700, version: String = "1.6.0", minimum: String = "13.0",
          url: String = "https://stillleaf.invalid/download/Stillleaf-1.6.0.dmg", notes: String? = nil,
          schema: Int = 1, app: String = "com.bookspresence.app", sha: String = String(repeating: "ab", count: 32)) -> Data {
    var latest: [String: Any] = ["version": version, "build": build, "minimumSystemVersion": minimum, "url": url, "sha256": sha]
    if let notes { latest["releaseNotesURL"] = notes }
    return try! JSONSerialization.data(withJSONObject: ["schemaVersion": schema, "bundleIdentifier": app, "latest": latest] as [String: Any])
}

let parsed = try UpdateFeed.parse(feed(notes: "https://stillleaf.invalid/releases/1.6.0"), bundleIdentifier: identifier)
if case .available(let release) = parsed.availability(currentBuild: 612, system: ventura) {
    check(release.pageURL.absoluteString == "https://stillleaf.invalid/releases/1.6.0", "Release notes should be the page opened")
} else { check(false, "A newer build must be offered") }
check(parsed.availability(currentBuild: 700, system: ventura) == .upToDate, "The same build is up to date")
check(parsed.availability(currentBuild: 900, system: ventura) == .upToDate, "An older feed never offers a downgrade")
let sonomaOnly = try UpdateFeed.parse(feed(minimum: "14.2"), bundleIdentifier: identifier)
if case .requiresNewerSystem = sonomaOnly.availability(currentBuild: 612, system: ventura) {} else { check(false, "A newer macOS requirement must not be offered") }
for data in [feed(url: "http://stillleaf.invalid/x.dmg"), feed(url: "https://u:p@stillleaf.invalid/x.dmg"), feed(notes: "file:///Applications"),
             feed(schema: 2), feed(app: "com.example.other"), feed(sha: "short"), feed(version: "1.6"), feed(build: 0),
             feed(minimum: "fourteen"), Data("{".utf8), Data(count: UpdateFeed.maximumSize + 1)] {
    check((try? UpdateFeed.parse(data, bundleIdentifier: identifier)) == nil, "Unsafe or foreign feeds must be rejected")
}

struct Stub: UpdateFeedTransport {
    let status: Int
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        check(request.value(forHTTPHeaderField: "User-Agent") == "Stillleaf/1.5.0", "The request must name only the app version")
        check(request.httpMethod == "GET" && request.httpBody == nil, "The request must not carry a body")
        return (feed(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
let feedURL = URL(string: "https://stillleaf.invalid/updates/macos.json")!
let checker = UpdateChecker(feedURL: feedURL, bundleIdentifier: identifier, version: "1.5.0", build: 612, transport: Stub(status: 200))
if case .available(let release) = try await checker.check(system: ventura) { check(release.build == 700, "Checker should report the feed build") }
else { check(false, "Checker should find the update") }
do {
    _ = try await UpdateChecker(feedURL: feedURL, bundleIdentifier: identifier, version: "1.5.0", build: 612, transport: Stub(status: 503)).check(system: ventura)
    check(false, "Server errors are not feeds")
} catch { check(error as? UpdateFeedError == .unavailable("The update server answered with status 503."), "Server errors need a clear message") }
check(UpdateChecker(bundle: .main) == nil, "A bundle without a feed URL must never check")

print("update-feed-smoke: passed")

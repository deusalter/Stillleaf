import Foundation

/// The JSON update feed published next to each release (docs/DISTRIBUTION.md#update-feed).
/// Stillleaf only reads it to tell the reader a newer version exists; the download itself goes
/// through the browser, so Gatekeeper checks the notarized disk image as usual.
public struct UpdateFeed: Decodable, Equatable, Sendable {
    public static let schemaVersion = 1
    /// Feeds are a few hundred bytes; anything far larger is not a feed.
    public static let maximumSize = 64 * 1024

    public let schemaVersion: Int
    public let bundleIdentifier: String
    public let latest: UpdateRelease

    public static func parse(_ data: Data, bundleIdentifier: String) throws -> UpdateFeed {
        guard data.count <= maximumSize else { throw UpdateFeedError.invalid("The update feed is too large.") }
        let feed: UpdateFeed
        do { feed = try JSONDecoder().decode(UpdateFeed.self, from: data) }
        catch { throw UpdateFeedError.invalid("The update feed could not be read.") }
        guard feed.schemaVersion == schemaVersion else { throw UpdateFeedError.invalid("The update feed uses an unsupported format.") }
        guard feed.bundleIdentifier == bundleIdentifier else { throw UpdateFeedError.invalid("The update feed is for a different app.") }
        try feed.latest.validate()
        return feed
    }

    /// Build numbers decide: they increase with every release commit, while marketing versions
    /// are for people. A release that needs a newer macOS is reported, never offered.
    public func availability(currentBuild: Int, system: OperatingSystemVersion) -> UpdateAvailability {
        guard latest.build > currentBuild else { return .upToDate }
        guard let minimum = latest.minimumSystem, Self.version(system, atLeast: minimum) else {
            return .requiresNewerSystem(latest)
        }
        return .available(latest)
    }

    static func version(_ system: OperatingSystemVersion, atLeast minimum: OperatingSystemVersion) -> Bool {
        (system.majorVersion, system.minorVersion, system.patchVersion)
            >= (minimum.majorVersion, minimum.minorVersion, minimum.patchVersion)
    }
}

public struct UpdateRelease: Decodable, Equatable, Sendable {
    public let version: String
    public let build: Int
    public let minimumSystemVersion: String
    public let url: URL
    public let sha256: String
    public let size: Int?
    public let releaseNotesURL: URL?
    public let publishedAt: String?

    /// The page to open for this release: its notes when published, otherwise the download.
    public var pageURL: URL { releaseNotesURL ?? url }

    var minimumSystem: OperatingSystemVersion? {
        let parts = minimumSystemVersion.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let values = parts.compactMap { $0 } + [0, 0]
        return OperatingSystemVersion(majorVersion: values[0], minorVersion: values[1], patchVersion: values[2])
    }

    func validate() throws {
        guard build > 0, version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw UpdateFeedError.invalid("The update feed lists an invalid version.")
        }
        guard minimumSystem != nil else { throw UpdateFeedError.invalid("The update feed lists an invalid macOS requirement.") }
        guard sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw UpdateFeedError.invalid("The update feed lists an invalid checksum.")
        }
        for link in [url, releaseNotesURL].compactMap({ $0 }) where !Self.isPublicHTTPS(link) {
            throw UpdateFeedError.invalid("The update feed lists a link that is not a secure web address.")
        }
    }

    public static func isPublicHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }
}

public enum UpdateAvailability: Equatable, Sendable {
    case upToDate
    case available(UpdateRelease)
    case requiresNewerSystem(UpdateRelease)
}

public enum UpdateFeedError: LocalizedError, Equatable {
    case invalid(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): return message
        }
    }
}

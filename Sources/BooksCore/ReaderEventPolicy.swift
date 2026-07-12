import Foundation

public struct ReaderLocator: Codable, Equatable {
    public var version: Int = 1
    public var publicationID: String
    public var href: String
    public var anchor: String?
    public var progression: Double?
    public var quote: String?
    public init(publicationID: String, href: String, anchor: String? = nil,
                progression: Double? = nil, quote: String? = nil) {
        self.publicationID = publicationID; self.href = href; self.anchor = anchor
        self.progression = progression; self.quote = quote
    }

    public var isValid: Bool {
        guard version == 1, !publicationID.isEmpty, publicationID.utf8.count <= 256,
              Self.safeResource(href), (anchor?.utf8.count ?? 0) <= 16_384,
              (quote?.utf8.count ?? 0) <= 32_768 else { return false }
        return progression.map { $0.isFinite && (0...1).contains($0) } ?? true
    }

    private static func safeResource(_ href: String) -> Bool {
        guard !href.isEmpty, href.utf8.count <= 4_096,
              let decoded = href.removingPercentEncoding else { return false }
        // Locators name package resources, never external URLs or file paths.
        return !decoded.hasPrefix("/") && !decoded.contains(":") && !decoded.contains("\\")
            && !decoded.contains("\0") && !decoded.contains("?") && !decoded.contains("#")
            && !decoded.contains("%")
            && !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }
}

public enum ReaderNavigationCause: String, Codable {
    case turn, scroll, assistiveNavigation, selection, restore, layout, jump, heartbeat
}

public struct ReaderNavigationEvent: Equatable {
    public var documentToken: String
    public var sequence: UInt64
    public var cause: ReaderNavigationCause
    public var locator: ReaderLocator
    public var observedAtUptime: TimeInterval
    public init(documentToken: String, sequence: UInt64, cause: ReaderNavigationCause,
                locator: ReaderLocator, observedAtUptime: TimeInterval) {
        self.documentToken = documentToken; self.sequence = sequence; self.cause = cause
        self.locator = locator; self.observedAtUptime = observedAtUptime
    }
}

public struct AcceptedReaderNavigation: Equatable {
    public let locator: ReaderLocator
    public let countsAsActivity: Bool
    // No pages-read field: relocation never establishes how much was read.
}

/// Validates host-normalized renderer events. Native bridge origin/frame checks
/// and host-owned timestamps are required before calling this policy.
public struct ReaderEventPolicy {
    private let publicationID: String
    private let documentToken: String
    private let openedAtUptime: TimeInterval
    private var lastSequence: UInt64?
    public init(publicationID: String, documentToken: String, openedAtUptime: TimeInterval) {
        self.publicationID = publicationID; self.documentToken = documentToken
        self.openedAtUptime = openedAtUptime
    }

    public mutating func accept(_ event: ReaderNavigationEvent, receiptUptime: TimeInterval,
                                eligible: Bool) -> AcceptedReaderNavigation? {
        guard !documentToken.isEmpty, event.documentToken == documentToken,
              event.locator.publicationID == publicationID, event.locator.isValid,
              lastSequence.map({ event.sequence > $0 }) ?? true,
              openedAtUptime.isFinite, receiptUptime.isFinite, event.observedAtUptime.isFinite,
              openedAtUptime >= 0, event.observedAtUptime >= openedAtUptime,
              event.observedAtUptime <= receiptUptime,
              receiptUptime - event.observedAtUptime <= 3 else { return nil }
        lastSequence = event.sequence
        let interaction: Bool
        switch event.cause {
        case .turn, .scroll, .assistiveNavigation, .selection: interaction = true
        case .restore, .layout, .jump, .heartbeat: interaction = false
        }
        return AcceptedReaderNavigation(locator: event.locator, countsAsActivity: eligible && interaction)
    }
}

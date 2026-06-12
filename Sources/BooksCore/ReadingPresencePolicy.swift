import Foundation

public enum ReadingPresenceState: String { case hidden, reading, paused }

/// Page metadata takes precedence over generic interaction, even when a later
/// sample temporarily omits its page label.
public struct ReadingActivityEvidence {
    private var bookID: String?
    private var navigationToken: String?
    public init() {}
    public mutating func observe(bookID: String, navigationToken: String?, relevantActivity: Bool) -> Bool {
        let newBook = self.bookID != bookID
        if newBook { self.navigationToken = nil }
        let pageChanged = navigationToken != nil && navigationToken != self.navigationToken
        let inputFallback = self.navigationToken == nil && navigationToken == nil && relevantActivity
        self.bookID = bookID
        if let navigationToken { self.navigationToken = navigationToken }
        return newBook || pageChanged || inputFallback
    }
}

/// Visibility is independent of credited reading time. This state is ephemeral;
/// relaunching never restores a stale Discord card from reading history.
public struct ReadingPresencePolicy {
    public let inactivityTimeout: TimeInterval
    private var bookID: String?
    private var lastActivity: TimeInterval?
    private var activityEvidence = ReadingActivityEvidence()
    private var lastObservation: TimeInterval?

    public init(inactivityTimeout: TimeInterval = 20 * 60) {
        self.inactivityTimeout = inactivityTimeout.isFinite ? max(0, inactivityTimeout) : 20 * 60
    }

    public mutating func reset() {
        bookID = nil; lastActivity = nil; activityEvidence = ReadingActivityEvidence(); lastObservation = nil
    }

    /// Automatic sessions must supply a freshly verified foreground reader;
    /// explicit manual sessions supply their existing manual activity evidence.
    /// Once page metadata
    /// exists, pointer motion or an app switch cannot renew the page-turn timeout.
    @discardableResult
    public mutating func observe(bookID: String, navigationToken: String?, relevantActivity: Bool,
                                 uptime: TimeInterval) -> Bool {
        guard uptime.isFinite else { reset(); return false }
        if let previous = lastObservation, uptime < previous { reset() }
        let activity = activityEvidence.observe(bookID: bookID, navigationToken: navigationToken, relevantActivity: relevantActivity)
        self.bookID = bookID
        if activity { lastActivity = uptime }
        lastObservation = uptime
        return activity
    }

    public mutating func state(for snapshot: TrackerSnapshot, book: BookRecord?, enabled: Bool,
                               readerOpen: Bool, uptime: TimeInterval) -> ReadingPresenceState {
        guard readerOpen else { reset(); return .hidden }
        guard enabled, let book, !book.trackingExcluded, !book.sharingExcluded else { reset(); return .hidden }
        if snapshot.phase == .paused,
           snapshot.pauseReason != .background && snapshot.pauseReason != .noReadingWindow {
            reset(); return .hidden
        }
        guard uptime.isFinite, let lastActivity, uptime >= lastActivity else { reset(); return .hidden }
        // Keep the expired observation: unchanged polling must not resurrect it.
        guard self.bookID == book.id, uptime - lastActivity < inactivityTimeout else { return .hidden }
        return snapshot.phase == .reading ? .reading : .paused
    }
}

import Foundation

/// Deletions that have to outlive the rows they removed. The journal deletes for real (a privacy deletion leaves
/// nothing behind), so without a note of what was deleted, the next sync would bring it back from another device.
public struct SyncTombstones: Codable, Equatable {
    /// Deleted reading sessions by session id, with when they were deleted.
    public var sessions: [String: Date]
    /// Deleted books by journal book id. A book observed again after its deletion (imported afresh) is a new
    /// book as far as its tombstone is concerned.
    public var books: [String: Date]

    public init(sessions: [String: Date] = [:], books: [String: Date] = [:]) {
        self.sessions = sessions
        self.books = books
    }

    public var isEmpty: Bool { sessions.isEmpty && books.isEmpty }

    public mutating func deleteSession(_ id: String, at date: Date) {
        guard !id.isEmpty else { return }
        sessions[id] = max(sessions[id] ?? date, date)
    }

    public mutating func deleteBook(_ id: String, at date: Date) {
        guard !id.isEmpty else { return }
        books[id] = max(books[id] ?? date, date)
    }

    /// Takes every deletion another device knows of. Returns whether anything was new.
    @discardableResult
    public mutating func merge(_ other: SyncTombstones) -> Bool {
        let before = self
        for (id, date) in other.sessions { deleteSession(id, at: date) }
        for (id, date) in other.books { deleteBook(id, at: date) }
        return self != before
    }

    /// Forgets deletions older than `cutoff`. By then every device that syncs has long applied them.
    public mutating func prune(before cutoff: Date) {
        sessions = sessions.filter { $0.value >= cutoff }
        books = books.filter { $0.value >= cutoff }
    }

    /// True when the tombstone for this book still applies to this record of it.
    public func covers(_ book: BookRecord) -> Bool {
        books[book.id].map { book.observedAt <= $0 } ?? false
    }

    /// An archive without anything these deletions cover, still consistent with itself: a deleted interval takes
    /// with it the corrections built on it and the page events it anchored.
    public func filtering(_ archive: HistoryArchive) -> HistoryArchive {
        guard !isEmpty else { return archive }
        var result = archive
        let goneBooks = Set(archive.books.filter(covers).map(\.id))
        result.books.removeAll { goneBooks.contains($0.id) }
        func gone(_ interval: ReadingInterval) -> Bool { goneBooks.contains(interval.bookID) || sessions[interval.sessionID] != nil }
        var removed = Set(archive.intervals.filter(gone).map(\.id))
        // A correction is dropped with any interval it touches; its other replacements go with it, and so on down the chain.
        var corrections = archive.corrections
        var changed = true
        while changed {
            changed = false
            corrections.removeAll { correction in
                let touches = correction.originalIDs.contains(where: removed.contains) || correction.replacements.contains { removed.contains($0.id) || gone($0) }
                guard touches else { return false }
                for id in correction.originalIDs + correction.replacements.map(\.id) where removed.insert(id).inserted { changed = true }
                return true
            }
        }
        result.corrections = corrections
        result.intervals.removeAll { removed.contains($0.id) }
        result.events.removeAll { event in
            event.bookID.map(goneBooks.contains) == true || event.sessionID.map { sessions[$0] != nil } == true
        }
        result.progress.removeAll { goneBooks.contains($0.bookID) }
        result.merges.removeAll { goneBooks.contains($0.sourceID) || goneBooks.contains($0.targetID) }
        return result
    }
}

/// What one merge of another device's journal did.
public struct SyncMergeReport: Equatable {
    /// Reading intervals that were new to this device.
    public var addedIntervals = 0
    public var addedBooks = 0
    public var addedEvents = 0
    /// Sessions left out because they overlap reading already recorded here: one person cannot have read
    /// two things at once, and the journal refuses overlapping time.
    public var skippedSessions: [String] = []
    /// Edits to a session that this device has already edited differently.
    public var skippedCorrections = 0
    public init() {}
    public var changedAnything: Bool { addedIntervals + addedBooks + addedEvents > 0 }

    public mutating func add(_ other: SyncMergeReport) {
        addedIntervals += other.addedIntervals
        addedBooks += other.addedBooks
        addedEvents += other.addedEvents
        skippedSessions += other.skippedSessions
        skippedCorrections += other.skippedCorrections
    }
}

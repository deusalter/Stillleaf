import Foundation
import BooksCore
import BooksPlatform

// Local check for the platform-neutral iOS model, compiled on macOS by check-model-local.sh.
// The iOS XCTest bundle covers the same behaviour on a simulator in CI.

final class ManualClock {
    var date = Date(timeIntervalSince1970: 1_790_000_000)
    var uptime: TimeInterval = 10_000
    func advance(_ seconds: TimeInterval) { date += seconds; uptime += seconds }
    var reading: Journal.Clock { { (self.date, self.uptime) } }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    guard condition() else { FileHandle.standardError.write(Data("ios-model-smoke FAILED line \(line): \(message)\n".utf8)); exit(1) }
}

@MainActor
func temporaryJournal(_ clock: ManualClock) throws -> Journal {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillleaf-ios-smoke-" + UUID().uuidString)
    let defaults = UserDefaults(suiteName: "stillleaf-ios-smoke-" + UUID().uuidString)!
    return try Journal(paths: JournalPaths(root: root), defaults: defaults, usesTimer: false, clock: clock.reading)
}

@MainActor
func run(rendererShell: URL?) async throws {
    let clock = ManualClock()
    let journal = try temporaryJournal(clock)
    check(journal.dailyGoal?.resolvedUnit == .pages && journal.dailyGoal?.pages == 20, "default goal is 20 pages")

    // Import a generated EPUB through the portable or system extractor.
    let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("stillleaf-ios-fixtures-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    let epub = try SyntheticEPUB.write(SyntheticEPUB.book(), to: fixtures.appendingPathComponent("garden.epub"))
    await journal.importEPUBs([epub])
    check(journal.editions.count == 1, "edition imported: \(journal.notice?.message ?? "")")
    let edition = journal.editions.values.first!
    check(journal.book(edition.bookID)?.source == "stillleaf-epub", "journal book registered")
    check(edition.coverURL.map { CoverThumbnails.thumbnail($0, maxPixels: 64) != nil } == true, "cover decodes")
    await journal.importEPUBs([epub])
    check(journal.editions.count == 1, "duplicate import is idempotent")

    // Reader not ready: nothing credited.
    journal.readerOpened(bookID: edition.bookID)
    for _ in 0..<5 { clock.advance(1); journal.tick() }
    check(journal.tracker.phase == .paused && journal.pauseReason == .noReadingWindow, "no credit before ready")

    // Ready and active: one-second samples credit time.
    journal.readerBecameReady(bookID: edition.bookID)
    for _ in 0..<30 { clock.advance(1); journal.tick() }
    check(journal.tracker.phase == .reading, "reading once ready")
    check(abs(journal.tracker.sessionSeconds - 30) < 0.01, "30 s credited, got \(journal.tracker.sessionSeconds)")
    let session = journal.tracker.sessionID

    // Forward coverage inside the credited session becomes page evidence.
    let departureJSON: [String: Any] = ["href": edition.publication.spine[0], "page": 1, "totalPages": 4, "visiblePages": 1,
                                        "pageUnit": "screen", "bookOffset": 0, "bookTotal": 1000, "lower": 0, "upper": 250]
    let departure = try JSONDecoder().decode(NativeReaderPosition.self, from: JSONSerialization.data(withJSONObject: departureJSON))
    journal.readerTraversed(bookID: edition.bookID, evidence: departure.forwardCoverage(spine: edition.publication.spine)!)
    journal.refresh()
    check(journal.pagesRead(bookID: edition.bookID) == 1, "one covered page recorded, got \(journal.pagesRead(bookID: edition.bookID))")

    // Inactive scene: paused at once, nothing credited while away.
    journal.sceneActivityChanged(active: false)
    check(journal.tracker.phase == .paused && journal.tracker.pauseReason == .background, "inactive pauses")
    for _ in 0..<60 { clock.advance(1); journal.tick() }
    journal.sceneActivityChanged(active: true)
    clock.advance(1); journal.tick()
    check(journal.tracker.phase == .reading && journal.tracker.sessionID == session, "short interruption resumes the session")

    // A suspension the app never saw (a monotonic gap) is not credited.
    let before = journal.tracker.sessionSeconds
    clock.advance(600); journal.tick()
    check(journal.tracker.sessionSeconds <= before + 1, "gap not credited")
    for _ in 0..<5 { clock.advance(1); journal.tick() }

    // Tracking off and excluded books credit nothing.
    journal.setTrackingEnabled(false)
    check(journal.tracker.phase == .paused && journal.pauseReason == .disabled, "tracking off pauses")
    journal.setTrackingEnabled(true)
    journal.readerMoved(departure.observation(bookID: edition.bookID, spine: edition.publication.spine, date: clock.date)!)
    journal.readerClosed(bookID: edition.bookID)
    check(journal.position(bookID: edition.bookID)?.location?.hasPrefix("Chapter 1 of 3") == true, "final position saved")
    let credited = journal.history.today.creditedSeconds
    check(credited >= 34 && credited <= 38, "today has ~36 s, got \(credited)")

    journal.setTrackingExcluded(true, for: edition.bookID)
    journal.readerOpened(bookID: edition.bookID); journal.readerBecameReady(bookID: edition.bookID)
    for _ in 0..<10 { clock.advance(1); journal.tick() }
    check(journal.tracker.phase == .paused && journal.tracker.pauseReason == .excludedBook, "excluded book is not tracked")
    journal.readerClosed(bookID: edition.bookID)
    journal.setTrackingExcluded(false, for: edition.bookID)

    // Manual reading for a paper book, validated like the Mac.
    let paper = BookRecord(id: "manual:" + UUID().uuidString, title: "Paper Book", observedAt: clock.date)
    clock.advance(3_600)
    check(journal.logReading(book: paper, end: clock.date, minutes: 25, pages: 12), "manual log saved")
    check(!journal.logReading(book: paper, end: clock.date, minutes: 10, pages: nil), "overlap rejected")
    journal.notice = nil
    check(journal.history.today.creditedSeconds >= credited + 1_500 - 1, "manual minutes counted")

    // Completion, rating, review and goals write the Mac's audit events.
    check(journal.markFinished(paper.id), "finished")
    check(journal.saveRating(4.25, for: paper.id) && journal.rating(bookID: paper.id) == 4.25, "rating")
    check(!journal.saveRating(4.1, for: paper.id), "quarter steps only"); journal.notice = nil
    check(journal.saveReview("  Quiet and good.  ", for: paper.id) && journal.review(bookID: paper.id) == "Quiet and good.", "review")
    check(journal.saveGoals(unit: .minutes, pages: 30, minutes: 45, annualBooks: 12), "goals")
    check(journal.dailyGoal?.resolvedUnit == .minutes && journal.dailyGoal?.minutes == 45 && journal.history.annualBookGoal == 12, "goal values")
    check(journal.history.annualBooksFinished == 1, "yearly count")

    // Mac-compatible JSON, CSV and SQLite backups round-trip into a fresh journal.
    let json = try journal.exportJSON()
    let csv = try journal.exportCSV()
    let backup = try journal.backup()
    check(FileManager.default.fileExists(atPath: csv.appendingPathComponent("effective_intervals.csv").path), "csv tables")
    let mac = try ReadingStore(url: fixtures.appendingPathComponent("mac.sqlite"))
    try mac.importJSON(from: json)
    let macBooks = try mac.archive().books.count
    check(macBooks == journal.history.books.count, "Mac store reads iOS JSON")
    let other = try temporaryJournal(ManualClock())
    check(other.importJSON(from: json), "import JSON")
    check(other.history.intervals.count == journal.history.intervals.count && other.review(bookID: paper.id) == "Quiet and good.", "JSON round trip")
    check(other.importJSON(from: json), "duplicate-safe re-import")
    let restored = try temporaryJournal(ManualClock())
    check(restored.restore(from: backup), "restore backup")
    check(restored.history.intervals.count == journal.history.intervals.count, "backup round trip")

    // Reader event gate: the Mac's acceptance rules.
    var gate = ReaderEventGate(publication: edition.publication, token: "token")
    let encoded = departureJSON
    func message(_ event: [String: Any], token: String = "token") -> [String: Any] { ["token": token, "event": event] }
    let now = Date()
    let position: [String: Any] = ["type": "position", "editionId": edition.publication.id, "sequence": 1,
                                   "observedAt": now.timeIntervalSince1970 * 1000, "position": encoded]
    check(gate.classify(message(position, token: "other"), fromSessionMainFrame: true, now: now) == .ignored, "wrong token")
    check(gate.classify(message(position), fromSessionMainFrame: false, now: now) == .ignored, "subframe")
    if case .position = gate.classify(message(position), fromSessionMainFrame: true, now: now) {} else { check(false, "position accepted") }
    check(gate.classify(message(position), fromSessionMainFrame: true, now: now) == .ignored, "replayed sequence")
    var turn = position; turn["type"] = "pageTurn"; turn["sequence"] = 2; turn["direction"] = "forward"; turn["departure"] = encoded
    if case .forwardCoverage = gate.classify(message(turn), fromSessionMainFrame: true, now: now) {} else { check(false, "coverage accepted") }
    turn["sequence"] = 3; turn["direction"] = "backward"
    check(gate.classify(message(turn), fromSessionMainFrame: true, now: now) == .ignored, "backward turn ignored")
    var stale = position; stale["sequence"] = 9; stale["observedAt"] = (now.timeIntervalSince1970 - 30) * 1000
    check(gate.classify(message(stale), fromSessionMainFrame: true, now: now) == .ignored, "stale event")
    check(gate.classify(message(["type": "ready", "editionId": "wrong"]), fromSessionMainFrame: true, now: now) == .ignored, "other edition")
    check(gate.classify(message(["type": "ready", "editionId": edition.publication.id]), fromSessionMainFrame: true, now: now) == .ready, "ready")

    // The shared launch payload, when a renderer build is available.
    if let rendererShell {
        let launch = try ReaderLaunch.prepare(publication: edition.publication, directory: edition.directory,
                                              shellCandidates: [rendererShell], stateDirectory: journal.paths.readerState)
        let payload = try JSONSerialization.jsonObject(with: Data(launch.payload.utf8)) as! [String: Any]
        check(payload["editionId"] as? String == edition.publication.id && (payload["readingOrder"] as? [Any])?.count == 3, "launch payload")
        check(launch.resources.url(for: "index.html") != nil, "renderer shell mapped")
    }

    // Removing the download keeps history; deleting the book removes both.
    let removedDownload = journal.removeDownload(edition.bookID)
    check(removedDownload && journal.editions.isEmpty, "download removed: \(removedDownload) \(journal.editions.keys) \(journal.notice?.message ?? "")")
    check(journal.book(edition.bookID) != nil, "history kept")
    await journal.importEPUBs([epub])
    check(journal.deleteBook(edition.bookID) && journal.editions.isEmpty && journal.book(edition.bookID) == nil, "book deleted")
    check(journal.deleteAllData() && journal.history.books.isEmpty && journal.dailyGoal != nil, "delete all keeps a default goal")
    print("ios-model-smoke: import, foreground-only tracking, coverage, manual log, journal edits, goals, Mac-format export/import/backup, event gate\(rendererShell == nil ? "" : ", launch payload") and deletion passed")
}

@main
struct ModelSmoke {
    static func main() async {
        let shell = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
        do { try await run(rendererShell: shell) } catch {
            FileHandle.standardError.write(Data("ios-model-smoke FAILED: \(error)\n".utf8)); exit(1)
        }
    }
}

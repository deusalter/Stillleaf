import XCTest
import UIKit
import BooksCore
@testable import Stillleaf

/// End to end in the simulator: a synthetic EPUB in the bundled renderer inside a real
/// WKWebView, with the same scheme handler, content rules and event validation as the Mac.
@MainActor
final class ReaderIntegrationTests: XCTestCase {
    func testOpensABookTurnsPagesCreditsTimeAndSavesPosition() async throws {
        let scratch = try Scratch()
        let journal = try scratch.journal()
        await journal.importEPUBs([try scratch.epub(entries: SyntheticEPUB.book(chapters: 3, paragraphs: 80))])
        let edition = try XCTUnwrap(journal.editions.values.first, journal.notice?.message ?? "import failed")

        var events: [ReaderEventGate.Event] = []
        var closed = false
        let reader = ReaderViewController(edition: edition, journal: journal) { closed = true }
        reader.eventObserver = { events.append($0) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = reader
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        try await waitUntil("the renderer to report ready", timeout: 120) { events.contains(.ready) }
        XCTAssertTrue(reader.isReady)
        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            journal.tick()
        }
        XCTAssertEqual(journal.tracker.phase, .reading, "the open, ready reader is credited")

        func positions() -> Int { events.filter { if case .position = $0 { return true }; return false }.count }
        let before = positions()
        for _ in 0..<4 {
            _ = try await reader.evaluate("window.StillleafReader.next(); true")
            try await Task.sleep(nanoseconds: 1_200_000_000)
            journal.tick()
        }
        try await waitUntil("position events after turning pages", timeout: 30) { positions() > before }
        let coverage = events.filter { if case .forwardCoverage = $0 { return true }; return false }.count
        XCTAssertGreaterThan(coverage, 0, "forward turns report sequential coverage")

        await reader.requestClose()
        XCTAssertTrue(closed)
        XCTAssertNil(journal.readingBookID)
        XCTAssertEqual(journal.tracker.phase, .paused)
        XCTAssertGreaterThanOrEqual(journal.history.today.creditedSeconds, 3)
        XCTAssertGreaterThan(journal.pagesRead(bookID: edition.bookID), 0)
        XCTAssertNotNil(journal.position(bookID: edition.bookID)?.location)
        let state = journal.paths.readerState.appendingPathComponent(edition.publication.id + ".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path), "reader state saved for the next open")
    }
}

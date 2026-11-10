import XCTest
import UIKit
import BooksCore
import BooksPlatform
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

        // The renderer hands its controls to the app: no web toolbar, hand-held metrics, real rows and settings.
        let chrome = reader.chrome
        func page(_ condition: String) async throws -> Bool { try await reader.evaluate(condition) as? Bool == true }
        func waitForPage(_ description: String, _ condition: String) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !(try await page(condition)) {
                guard Date() < deadline else { throw TimeoutError(description: "Timed out waiting for \(description)") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        try await waitUntil("the native controls to connect", timeout: 30) { chrome.connected }
        let webToolbarHidden = try await page("document.body.classList.contains('native-chrome') && getComputedStyle(document.querySelector('.reader-bar')).display === 'none'")
        XCTAssertTrue(webToolbarHidden, "the app draws the controls, not the page")
        try await waitForPage("the touch policy", "document.body.classList.contains('native-touch')")
        if UIDevice.current.userInterfaceIdiom == .phone {
            try await waitUntil("the hand-held size on first open", timeout: 15) { chrome.number("fontSize") == 1.0 }
        }
        XCTAssertNotNil(chrome.control("theme")?.options?.first(where: { $0.background != nil }), "themes arrive with their colours")
        chrome.load(.outline)
        try await waitUntil("the table of contents", timeout: 20) { chrome.lists[.outline]?.rows.count == 3 }
        XCTAssertEqual(chrome.lists[.outline]?.rows.first?.title, "Chapter 1")
        XCTAssertFalse(chrome.controlsVisible)
        _ = try await reader.evaluate("window.dispatchEvent(new CustomEvent('stillleaf-reader-event', {detail: {version: 1, type: 'chrome-tap', editionId: '\(edition.publication.id)'}})); true")
        try await waitUntil("a tap on the page to show the controls", timeout: 10) { chrome.controlsVisible }
        try await waitForPage("the page to show its total beside the page number", "document.body.classList.contains('native-controlsVisible')")
        chrome.setControlsVisible(false)

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
        // The renderer finishes its whole-book count once turning stops, and it is kept for the next open.
        try await waitUntil("a finished page map", timeout: 90) { events.contains { if case .pageMap = $0 { return true }; return false } }

        let content = try XCTUnwrap(reader.webView).configuration.userContentController
        await reader.requestClose()
        XCTAssertTrue(closed)
        XCTAssertTrue(content.userScripts.isEmpty, "a closed reader detaches from its page so WebKit can release it")
        try await waitUntil("the page map to reach disk", timeout: 10) {
            !ReaderPageMapStore(stateDirectory: journal.paths.readerState).load(publication: edition.publication).isEmpty
        }
        let reopened = try ReaderLaunch.prepare(publication: edition.publication, directory: edition.directory,
                                                shellCandidates: [Bundle.main.bundleURL.appendingPathComponent("Reader")],
                                                stateDirectory: journal.paths.readerState)
        XCTAssertTrue(reopened.payload.contains("\"pageMaps\""), "a reopened book gets its saved page count at once")
        XCTAssertNil(journal.readingBookID)
        XCTAssertEqual(journal.tracker.phase, .paused)
        XCTAssertGreaterThanOrEqual(journal.history.today.creditedSeconds, 3)
        XCTAssertGreaterThan(journal.pagesRead(bookID: edition.bookID), 0)
        XCTAssertNotNil(journal.position(bookID: edition.bookID)?.location)
        let state = journal.paths.readerState.appendingPathComponent(edition.publication.id + ".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path), "reader state saved for the next open")
    }
}

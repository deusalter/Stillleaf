import XCTest
@testable import Stillleaf

/// The reader's controls against a stand-in renderer: what is sent, and what is shown.
@MainActor
final class ReaderChromeTests: XCTestCase {
    private var scratch: Scratch!
    private var sent: [(command: String, payload: [String: Any]?)] = []
    private var preferences: [String: Any] = [:]

    private let definitions: [[String: Any]] = [
        ["key": "theme", "label": "Page theme", "kind": "choice", "options": [
            ["value": "\"system\"", "label": "System", "background": "#ffffff", "text": "#0a57ad", "alternate": "#000000"] as [String: Any],
            ["value": "\"night\"", "label": "Night", "background": "#000000", "text": "#ffffff"] as [String: Any]
        ]],
        ["key": "fontSize", "label": "Text size", "kind": "number", "min": 0.5, "max": 3.0, "step": 0.01, "nullable": false]
    ]

    override func setUp() async throws {
        scratch = try Scratch()
        sent = []
        preferences = Self.rendererDefaults
    }

    override func tearDown() async throws { scratch = nil }

    private static let rendererDefaults: [String: Any] = ["theme": "system", "fontSize": 1.2, "scroll": false, "fontWeight": NSNull(), "textAlign": "publisher"]

    /// A chrome wired to a renderer that applies preferences after a short delay, like the real one.
    private func chrome() -> ReaderChrome {
        let chrome = ReaderChrome()
        chrome.defaults = scratch.defaults
        chrome.transport = { [unowned self] command, payload in
            self.sent.append((command, payload))
            if command == "preferences", let payload {
                for (key, value) in payload { self.preferences[key] = value }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            let night = self.preferences["theme"] as? String == "night"
            var response: [String: Any] = ["preferences": self.preferences, "definitions": self.definitions, "bookmarked": false, "dialogOpen": false,
                                           "effectiveAppearance": ["backgroundColor": night ? "#000000" : "#ffffff", "textColor": night ? "#ffffff" : "#111111"]]
            if command == "panel" {
                let child: [String: Any] = ["id": "o1", "title": "Chapter 1", "current": true, "openable": true, "page": 3]
                let part: [String: Any] = ["id": "o0", "title": "Part One", "openable": false, "children": [child]]
                response["panel"] = ["name": "outline", "rows": [part], "empty": "This book has no table of contents."] as [String: Any]
            }
            if command == "find" {
                let row: [String: Any] = ["id": "r0", "before": "the ", "match": "leaf", "after": " fell", "chapter": "Chapter 1"]
                response["panel"] = ["name": "search", "query": "leaf", "rows": [row], "status": "1 result"] as [String: Any]
            }
            return response
        }
        return chrome
    }

    private func settle(_ milliseconds: UInt64 = 200) async throws { try await Task.sleep(nanoseconds: milliseconds * 1_000_000) }

    func testControlsStayUpForVoiceOverAndStepAsideForSheets() async throws {
        var assisted = false
        let chrome = chrome()
        chrome.keepsControls = { assisted }
        await chrome.connect(firstOpen: false)
        XCTAssertFalse(chrome.controlsVisible, "reading starts on a clean page")

        assisted = true
        chrome.accessibilityChanged()
        XCTAssertTrue(chrome.controlsVisible, "VoiceOver cannot tap the middle of a page")
        chrome.setControlsVisible(false)
        chrome.toggleControls()
        XCTAssertTrue(chrome.controlsVisible, "and nothing puts them away")
        chrome.open(.contents)
        XCTAssertFalse(chrome.controlsVisible, "except a sheet in front")
        chrome.sheet = nil
        XCTAssertTrue(chrome.controlsVisible)
        chrome.turn(forward: true)
        try await settle()
        XCTAssertEqual(sent.last?.command, "next")

        assisted = false
        chrome.accessibilityChanged()
        chrome.toggleControls()
        XCTAssertFalse(chrome.controlsVisible, "without it a tap hides them again")
    }

    func testFirstOpenStartsHandHeldAndLaterBooksCarryTheLastAppearance() async throws {
        let first = chrome()
        first.firstOpenPreferences = ["fontSize": 1.0]
        await first.connect(firstOpen: true)
        XCTAssertTrue(first.connected)
        XCTAssertEqual(first.number("fontSize"), 1.0, "a book with no saved state starts at the hand-held size")
        XCTAssertEqual(first.controls.map(\.key), ["theme", "fontSize"])

        let night = try XCTUnwrap(first.control("theme")?.options?.last)
        first.choose(night, for: "theme")
        first.step("fontSize", by: 0.1)
        try await settle()
        XCTAssertTrue(first.isSelected(night, for: "theme"))
        XCTAssertTrue(first.pageIsDark)
        XCTAssertTrue(preferences["backgroundColor"] is NSNull, "a named theme clears custom page colours")

        preferences = Self.rendererDefaults
        let second = chrome()
        second.firstOpenPreferences = ["fontSize": 1.0]
        await second.connect(firstOpen: true)
        XCTAssertEqual(second.preferences["theme"] as? String, "night", "a new book starts with the appearance used last")
        XCTAssertEqual(second.number("fontSize") ?? 0, 1.1, accuracy: 0.001)

        preferences = Self.rendererDefaults.merging(["fontSize": 1.4]) { $1 }
        let saved = chrome()
        await saved.connect(firstOpen: false)
        XCTAssertEqual(saved.number("fontSize"), 1.4, "a book with its own saved state keeps it")
    }

    func testRapidChangesShowAtOnceAndCollapseToTheLastValue() async throws {
        let chrome = chrome()
        await chrome.connect(firstOpen: false)
        sent = []
        for size in [1.05, 1.1, 1.15, 1.2, 1.25] { chrome.set("fontSize", size) }
        XCTAssertEqual(chrome.number("fontSize"), 1.25, "the control shows the change before the renderer answers")
        try await settle(300)
        let batches = sent.filter { $0.command == "preferences" }
        XCTAssertLessThanOrEqual(batches.count, 2, "five changes during one round trip are not five requests")
        XCTAssertEqual(batches.last?.payload?["fontSize"] as? Double, 1.25)
        XCTAssertEqual(chrome.number("fontSize"), 1.25)
        chrome.step("fontSize", by: 10)
        try await settle()
        XCTAssertEqual(chrome.number("fontSize"), 3, "steps stay inside the range the renderer allows")
    }

    func testListsSendRowIdentifiersBackAndSheetsPutControlsAway() async throws {
        let chrome = chrome()
        await chrome.connect(firstOpen: false)
        chrome.toggleControls()
        XCTAssertTrue(chrome.controlsVisible)
        try await settle(60)
        let policy = sent.last(where: { $0.command == "policy" })?.payload
        XCTAssertEqual(policy?["controlsVisible"] as? Bool, true, "the page shows its total while the controls are up")
        XCTAssertEqual(policy?["touch"] as? Bool, true)

        chrome.open(.contents)
        XCTAssertFalse(chrome.controlsVisible, "a sheet replaces the controls")
        chrome.load(.outline)
        try await settle()
        let rows = try XCTUnwrap(chrome.lists[.outline]?.rows)
        XCTAssertEqual(rows.map(\.id), ["o0", "o1"])
        XCTAssertEqual(rows[1].depth, 1)
        XCTAssertEqual(rows[1].detail, "3")
        XCTAssertTrue(rows[1].current)
        XCTAssertFalse(rows[0].openable)

        chrome.go(rows[0])
        try await settle(80)
        XCTAssertFalse(sent.contains(where: { $0.command == "go" }), "a heading with no place in the book is not sent")
        chrome.go(rows[1])
        try await settle()
        XCTAssertEqual(sent.last(where: { $0.command == "go" })?.payload?["id"] as? String, "o1")
        XCTAssertNil(chrome.sheet, "opening a place returns to the page")

        chrome.find("l")
        XCTAssertEqual(chrome.search.status, "Enter at least two characters.")
        chrome.find("leaf")
        try await settle()
        XCTAssertEqual(chrome.search.rows.first?.match, "leaf")
        XCTAssertEqual(chrome.search.status, "1 result")

        chrome.accept(["dialogOpen": true])
        chrome.toggleControls()
        XCTAssertFalse(chrome.controlsVisible, "controls stay away while the renderer's note editor is open")
        chrome.disconnect()
        XCTAssertFalse(chrome.connected)
        XCTAssertTrue(chrome.lists.isEmpty)
    }
}

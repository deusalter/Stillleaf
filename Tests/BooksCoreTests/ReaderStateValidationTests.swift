import Foundation
import XCTest
@testable import BooksCore

final class ReaderStateValidationTests: XCTestCase {
    private let id = String(repeating: "a", count: 64)
    private var publication: EPUBPublication {
        EPUBPublication(id: id, title: "Fixture", authors: [], packagePath: "package.opf", resources: [EPUBResource(id: "chapter", path: "chapter.xhtml", mediaType: "application/xhtml+xml"), EPUBResource(id: "appendix", path: "appendix.xhtml", mediaType: "application/xhtml+xml")], spine: ["chapter.xhtml"], coverPath: nil, warnings: [])
    }
    private var state: [String: Any] {
        ["schemaVersion": 1, "editionId": id, "revision": 0, "position": NSNull(), "preferences": ["theme": "system", "fontFamily": "publisher", "fontSize": 1.2, "lineHeight": 1.6, "measure": 65] as [String: Any], "bookmarks": [], "annotations": []]
    }
    private func validate(_ value: [String: Any]) throws {
        try ReaderStateValidation.validate(JSONSerialization.data(withJSONObject: value), publication: publication)
    }
    func testSharedPreferenceBoundsAndNonlinearResource() throws {
        var value = state
        value["preferences"] = ["theme": "dark", "fontFamily": "sans", "fontSize": 3.0, "lineHeight": 3, "measure": 120] as [String: Any]
        value["position"] = ["href": "appendix.xhtml", "locations": ["progression": 1.0]] as [String: Any]
        XCTAssertNoThrow(try validate(value))
    }
    func testEveryAppearanceChoiceIsAcceptedAndUnknownOnesAreNot() throws {
        for (key, values) in [("theme", ReaderStateValidation.themes), ("fontFamily", ReaderStateValidation.fontFamilies), ("margins", ReaderStateValidation.marginChoices)] {
            for choice in values {
                var value = state
                var preferences = value["preferences"] as! [String: Any]
                preferences[key] = choice; value["preferences"] = preferences
                XCTAssertNoThrow(try validate(value), "\(key)=\(choice)")
            }
            var value = state
            var preferences = value["preferences"] as! [String: Any]
            preferences[key] = "unknown"; value["preferences"] = preferences
            XCTAssertThrowsError(try validate(value), key)
        }
    }
    /// The renderer writes these ids; a mismatch would make every save of a new choice fail.
    func testAppearanceIdsMatchTheRenderer() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Reader/desktop/reader/src/appearance.js")
        let text = try String(contentsOf: source, encoding: .utf8)
        func ids(between start: String, and end: String) throws -> Set<String> {
            let lower = try XCTUnwrap(text.range(of: start))
            let upper = try XCTUnwrap(text.range(of: end, range: lower.upperBound..<text.endIndex))
            let section = String(text[lower.upperBound..<upper.lowerBound])
            let pattern = try NSRegularExpression(pattern: "\\{id:'([a-z-]+)'")
            return Set(pattern.matches(in: section, range: NSRange(section.startIndex..., in: section)).compactMap {
                Range($0.range(at: 1), in: section).map { String(section[$0]) }
            })
        }
        XCTAssertEqual(try ids(between: "export const THEMES", and: "export const THEME_IDS").union(["system"]), ReaderStateValidation.themes)
        XCTAssertEqual(try ids(between: "export const FONTS", and: "export const FONT_IDS"), ReaderStateValidation.fontFamilies)
        let margins = try XCTUnwrap(text.range(of: "export const MARGINS"))
        let marginsEnd = try XCTUnwrap(text.range(of: "export const MARGIN_IDS"))
        let marginSection = String(text[margins.upperBound..<marginsEnd.lowerBound])
        XCTAssertEqual(Set(ReaderStateValidation.marginChoices.filter { marginSection.contains(" \($0):{") }), ReaderStateValidation.marginChoices)
        XCTAssertEqual(marginSection.components(separatedBy: ":{label:").count - 1, ReaderStateValidation.marginChoices.count)
    }
    func testOptionalAppearancePreservesLegacyAndValidBounds() throws {
        XCTAssertNoThrow(try validate(state))
        for theme in ["white", "stone", "mist", "forest", "dusk", "midnight", "custom"] {
            for family in ["literata", "source-serif", "lora", "libre-baskerville", "atkinson", "inter", "nunito", "source-sans", "georgia", "palatino", "monospace"] {
                var value = state; var preferences = state["preferences"] as! [String: Any]
                preferences.merge(["theme": theme, "fontFamily": family, "contentWidth": 40, "sideMargin": 96, "immersive": true, "backgroundColor": "#aBcD12", "textColor": NSNull()]) { _, new in new }
                value["preferences"] = preferences
                XCTAssertNoThrow(try validate(value))
            }
        }
    }
    func testAppearanceRejectsCoercionOutOfBoundsAndCSSColors() {
        let invalid: [(String, Any)] = [("contentWidth", true), ("contentWidth", 39.99), ("contentWidth", 100.01), ("sideMargin", false), ("sideMargin", -0.01), ("sideMargin", 96.01), ("immersive", 1), ("immersive", NSNull()), ("backgroundColor", "#112233\n"), ("textColor", "#fff"), ("textColor", "rgb(1,2,3)"), ("backgroundColor", "url(https://example.invalid)")]
        for (key, candidate) in invalid {
            var value = state; var preferences = state["preferences"] as! [String: Any]
            preferences[key] = candidate; value["preferences"] = preferences
            XCTAssertThrowsError(try validate(value), key)
        }
    }
    func testBooleansAreNotNumericVersionsOrRevisions() {
        for key in ["schemaVersion", "revision"] {
            var value = state; value[key] = true
            XCTAssertThrowsError(try validate(value), key)
        }
        var value = state; value["revision"] = 9_007_199_254_740_992.0
        XCTAssertThrowsError(try validate(value))
    }
    func testEditionAndLocatorFieldsMustMatchContract() {
        var value = state; value["editionId"] = "wrong"
        XCTAssertThrowsError(try validate(value))
        for locator in [["href": "../outside"], ["href": "chapter.xhtml", "locations": ["progression": 2]], ["href": "chapter.xhtml", "text": ["highlight": false]], ["href": "chapter.xhtml", "locations": ["position": 0]]] as [[String: Any]] {
            value = state; value["position"] = locator
            XCTAssertThrowsError(try validate(value))
        }
    }
    func testNoteAndBookmarkAreRetainedAndIndependentlyIdentified() throws {
        let locator = ["href": "chapter.xhtml"]
        var value = state
        value["bookmarks"] = [["id": "same", "locator": locator, "label": "Bookmark", "createdAt": "2026-09-24T12:00:00.123Z"] as [String: Any]]
        value["annotations"] = [["id": "same", "locator": locator, "note": "Personal note", "quote": "Passage", "color": "yellow", "createdAt": "2026-09-24T12:00:00Z", "updatedAt": "2026-09-24T12:00:00Z"] as [String: Any]]
        XCTAssertNoThrow(try validate(value))
        var annotations = value["annotations"] as! [[String: Any]]
        annotations[0]["updatedAt"] = "invalid"
        value["annotations"] = annotations
        XCTAssertThrowsError(try validate(value))
    }
    func testSavedDOMRangeBounds() throws {
        let point: [String: Any] = ["cssSelector": "p", "textNodeIndex": 0, "charOffset": 3]
        var value = state
        value["position"] = ["href": "chapter.xhtml", "locations": ["domRange": ["start": point, "end": point]]] as [String: Any]
        XCTAssertNoThrow(try validate(value))
        for invalid in [["cssSelector": "p", "charOffset": true], ["cssSelector": "p", "textNodeIndex": 10_000_001], ["cssSelector": "p", "unknown": 1]] as [[String: Any]] {
            value["position"] = ["href": "chapter.xhtml", "locations": ["domRange": ["start": invalid, "end": point]]] as [String: Any]
            XCTAssertThrowsError(try validate(value))
        }
    }
    func testPayloadSizeCountAndRequiredPreferences() throws {
        var value = state; value["preferences"] = [String: Any]()
        XCTAssertThrowsError(try validate(value))
        let bookmark: [String: Any] = ["id": "x", "locator": ["href": "chapter.xhtml"], "createdAt": "2026-09-24T12:00:00Z"]
        value = state; value["bookmarks"] = Array(repeating: bookmark, count: 2001)
        XCTAssertThrowsError(try validate(value))
        value = state; value["extra"] = String(repeating: "x", count: ReaderStateValidation.maximumBytes)
        XCTAssertThrowsError(try validate(value))
    }
}

extension ReaderStateValidationTests {
    func testLocatorTextLimitMatchesRendererUTF16Contract() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Reader/desktop/reader/src/annotation-anchor.js")
        XCTAssertTrue(try String(contentsOf: source, encoding: .utf8).contains("MAX_LOCATOR_TEXT=\(ReaderStateValidation.maximumLocatorText)"))
        for key in ["before", "highlight", "after"] {
            var value = state
            value["position"] = ["href": "chapter.xhtml", "text": [key: String(repeating: "😀", count: ReaderStateValidation.maximumLocatorText / 2)]]
            XCTAssertNoThrow(try validate(value))
            value["position"] = ["href": "chapter.xhtml", "text": [key: String(repeating: "😀", count: ReaderStateValidation.maximumLocatorText / 2) + "x"]]
            XCTAssertThrowsError(try validate(value))
        }
    }
}

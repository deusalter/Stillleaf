import XCTest

/// Sync between two devices through a folder: see `FolderSyncScenario.swift` for the story.
final class FolderSyncTests: XCTestCase {
    func testTwoDevicesStayInStepThroughAFolder() throws {
        var failures: [String] = []
        try runFolderSyncScenario { failures.append($0) }
        XCTAssertEqual(failures, [])
    }
}

import XCTest
@testable import BooksPlatform

final class InstallLocationTests: XCTestCase {
    func testInstallLocationClassification() {
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Applications/Stillleaf.app", volumeIsReadOnly: false), .installed)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Users/r/Applications/Stillleaf.app", volumeIsReadOnly: false), .installed)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/private/var/folders/x/T/AppTranslocation/1D2E/d/Stillleaf.app", volumeIsReadOnly: true), .translocated)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Volumes/Stillleaf/Stillleaf.app", volumeIsReadOnly: true), .readOnlyVolume)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Volumes/External/Applications/Stillleaf.app", volumeIsReadOnly: false), .installed)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/repo/.build/release", volumeIsReadOnly: false), .notBundled)
        XCTAssertTrue(InstallLocation.translocated.isTemporary && InstallLocation.readOnlyVolume.isTemporary)
        XCTAssertFalse(InstallLocation.installed.isTemporary || InstallLocation.notBundled.isTemporary)
    }
}

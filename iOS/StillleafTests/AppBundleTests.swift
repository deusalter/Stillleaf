import XCTest
@testable import Stillleaf

/// App Store packaging facts that are easy to lose in a project change.
final class AppBundleTests: XCTestCase {
    private let bundle = Bundle.main

    func testBundlesTheSharedRenderer() {
        let reader = bundle.bundleURL.appendingPathComponent("Reader")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reader.appendingPathComponent("index.html").path))
        let files = (FileManager.default.enumerator(atPath: reader.path)?.allObjects as? [String]) ?? []
        XCTAssertTrue(files.contains { $0.hasSuffix(".js") }, "renderer script")
        XCTAssertTrue(files.contains { $0.hasSuffix(".css") }, "renderer styles (fonts are inlined in the scripts)")
    }

    func testPrivacyManifestDeclaresNoTrackingAndEachRequiredReasonAPI() throws {
        let url = try XCTUnwrap(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        let reasons = Dictionary(uniqueKeysWithValues: ((manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? []).map {
            ($0["NSPrivacyAccessedAPIType"] as? String ?? "", $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
        })
        XCTAssertEqual(reasons, [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"]
        ])
    }

    func testInfoPlistExportComplianceDocumentsAndLaunchScreen() throws {
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool, false)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool, false)
        let types = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        XCTAssertTrue(types.contains { ($0["LSItemContentTypes"] as? [String])?.contains("org.idpf.epub-container") == true })
        XCTAssertNotNil(bundle.object(forInfoDictionaryKey: "UILaunchScreen"))
        XCTAssertNil(bundle.object(forInfoDictionaryKey: "UIBackgroundModes"), "no background execution")
        XCTAssertNil(bundle.object(forInfoDictionaryKey: "NSAppTransportSecurity"))
    }
}

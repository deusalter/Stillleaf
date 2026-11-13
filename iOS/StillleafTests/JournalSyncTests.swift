import XCTest
import BooksCore
import BooksPlatform
@testable import Stillleaf

/// Two journals, as on a Mac and an iPhone, kept in step through one folder. The merge rules themselves are
/// covered by the shared FolderSyncTests; this checks the app's side: what triggers a pass, how a book that
/// arrives is imported, and that deleting here deletes there.
@MainActor
final class JournalSyncTests: XCTestCase {
    func testABookItsHistoryAndItsDeletionCrossBetweenTwoJournals() async throws {
        let first = try Scratch(), second = try Scratch()
        let folder = first.url("Sync Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = try first.journal(), phone = try second.journal()
        mac.deviceName = "Mac"
        phone.deviceName = "iPhone"

        let imported = await mac.importEPUBs([try first.epub()])
        let bookID = try XCTUnwrap(imported.first, mac.notice?.message ?? "import failed")
        XCTAssertTrue(mac.logReading(book: try XCTUnwrap(mac.book(bookID)), end: Date().addingTimeInterval(-600), minutes: 25, pages: 12),
                      mac.notice?.message ?? "")

        XCTAssertFalse(mac.sync.enabled)
        mac.setSyncFolder(folder)
        XCTAssertTrue(mac.sync.enabled)
        XCTAssertNil(mac.sync.problem)
        XCTAssertNotNil(mac.sync.lastSync)
        XCTAssertEqual(mac.sync.devices, [], "no other device has used the folder yet")

        // The second device joins: history arrives at once, the book file a moment later.
        phone.setSyncFolder(folder)
        XCTAssertNil(phone.sync.problem)
        XCTAssertEqual(phone.sync.devices, ["Mac"])
        XCTAssertEqual(phone.secondsRead(bookID: bookID), 25 * 60, accuracy: 1)
        // The Mac copies its books into the folder in the background, so the phone may need another pass to see the file.
        try await waitUntil("the book to arrive on the second device", timeout: 30) {
            if phone.edition(forBook: bookID) == nil { phone.syncNow() }
            return phone.edition(forBook: bookID) != nil
        }
        XCTAssertEqual(phone.book(bookID)?.title, mac.book(bookID)?.title)

        mac.syncNow()
        XCTAssertEqual(mac.sync.devices, ["iPhone"])

        // Reading on the phone reaches the Mac.
        XCTAssertTrue(phone.logReading(book: try XCTUnwrap(phone.book(bookID)), end: Date().addingTimeInterval(-60), minutes: 5, pages: 3),
                      phone.notice?.message ?? "")
        phone.syncNow()
        mac.syncNow()
        XCTAssertEqual(mac.secondsRead(bookID: bookID), 30 * 60, accuracy: 1)

        // Deleting the book on the phone deletes it on the Mac, and neither brings it back.
        XCTAssertTrue(phone.deleteBook(bookID), phone.notice?.message ?? "")
        phone.syncNow()
        mac.syncNow()
        XCTAssertNil(mac.book(bookID))
        XCTAssertNil(mac.edition(forBook: bookID))
        phone.syncNow()
        mac.syncNow()
        XCTAssertNil(phone.book(bookID))
        XCTAssertNil(mac.book(bookID))
        XCTAssertNil(mac.sync.problem)

        // Turning sync off stops passes and forgets the folder.
        mac.turnOffSync()
        XCTAssertFalse(mac.sync.enabled)
        mac.syncNow()
        XCTAssertNil(mac.sync.lastSync)
    }

    /// The moments a full pass cannot cover: a book left open, a deletion made while sync is off, and
    /// deleting everything on one device.
    func testAnOpenBookIsPublishedAndWhatIsDeletedWhileOffStaysDeleted() async throws {
        let first = try Scratch(), second = try Scratch()
        let folder = first.url("Sync Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = try first.journal(), phone = try second.journal()
        mac.deviceName = "Mac"
        phone.deviceName = "iPhone"
        let imported = await mac.importEPUBs([try first.epub()])
        let bookID = try XCTUnwrap(imported.first, mac.notice?.message ?? "import failed")
        XCTAssertTrue(mac.logReading(book: try XCTUnwrap(mac.book(bookID)), end: Date().addingTimeInterval(-600), minutes: 10, pages: 5))
        mac.setSyncFolder(folder)
        phone.setSyncFolder(folder)
        try await waitUntil("the book to arrive on the second device", timeout: 30) {
            if phone.edition(forBook: bookID) == nil { phone.syncNow() }
            return phone.edition(forBook: bookID) != nil
        }
        let held = try XCTUnwrap(phone.edition(forBook: bookID))

        // The phone is put down with the book open. No full pass runs under an open book, but the place is published.
        phone.readerOpened(bookID: bookID)
        let locator: [String: Any] = ["href": held.publication.spine.first ?? "", "type": "application/xhtml+xml",
                                      "locations": ["progression": 0.4, "totalProgression": 0.4]]
        let state: [String: Any] = ["schemaVersion": 1, "editionId": held.publication.id, "revision": 1, "position": locator,
                                    "preferences": ["theme": "paper", "fontFamily": "serif", "fontSize": 1.2, "lineHeight": 1.6, "measure": 68],
                                    "bookmarks": [], "annotations": []]
        try ReaderStateStore(directory: phone.paths.readerState)
            .save(JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), publication: held.publication)
        let lastFullPass = phone.sync.lastSync
        phone.syncNow()
        XCTAssertEqual(phone.sync.lastSync, lastFullPass, "a full pass waits while a book is open")
        phone.publishForSync()
        XCTAssertNil(phone.sync.problem)
        mac.syncNow()
        let macEdition = try XCTUnwrap(mac.edition(forBook: bookID))
        let macState = try XCTUnwrap(ReaderStateStore(directory: mac.paths.readerState).load(publication: macEdition.publication))
        let position = (try JSONSerialization.jsonObject(with: macState) as? [String: Any])?["position"] as? [String: Any]
        XCTAssertEqual((position?["locations"] as? [String: Any])?["progression"] as? Double, 0.4, "the other device opens where the book was left open")
        phone.readerClosed(bookID: bookID)
        phone.syncNow()
        mac.syncNow()

        // A book deleted while sync is off is still deleted when sync comes back, here and on the other device.
        phone.turnOffSync()
        XCTAssertTrue(phone.deleteBook(bookID), phone.notice?.message ?? "")
        phone.setSyncFolder(folder)
        XCTAssertNil(phone.book(bookID), "the other device's journal does not hand the book back")
        mac.syncNow()
        XCTAssertNil(mac.book(bookID))

        // Deleting all data takes this device's copy of the journal out of the folder.
        let devices = folder.appendingPathComponent("devices", isDirectory: true)
        func deviceFolders() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: devices.path)) ?? []).filter { !$0.hasPrefix(".") }.count }
        XCTAssertEqual(deviceFolders(), 2)
        XCTAssertTrue(phone.deleteAllData(), phone.notice?.message ?? "")
        XCTAssertEqual(deviceFolders(), 1)
        XCTAssertFalse(phone.sync.enabled)
    }
}

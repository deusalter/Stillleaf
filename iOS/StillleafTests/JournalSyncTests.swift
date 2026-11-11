import XCTest
import BooksCore
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
        try await waitUntil("the book to arrive on the second device", timeout: 30) { phone.edition(forBook: bookID) != nil }
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
}

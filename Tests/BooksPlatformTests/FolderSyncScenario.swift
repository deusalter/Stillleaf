import Foundation
import BooksCore
import BooksPlatform

// Two devices, each with its own journal, books and reader state, syncing through one folder. This is the
// whole of sync except the apps' own screens: what crosses, what is left out, and what deletions do.
// It is compiled twice: into the XCTest target (FolderSyncTests) and into `scripts/sync-smoke.swift`, which
// `scripts/check-local.sh` runs on Macs that have no XCTest.

/// One device: what an app holds, and the pass an app runs.
final class SyncScenarioDevice {
    let name: String
    let store: ReadingStore
    let importer: EPUBPublicationImporter
    let readerStates: ReaderStateStore
    let stateDirectory: URL
    let sync: FolderSync
    var editions: [String: FolderSync.Edition] = [:]

    init(_ name: String, in root: URL, folder: URL) throws {
        self.name = name
        let home = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = try ReadingStore(url: home.appendingPathComponent("history.sqlite"))
        importer = EPUBPublicationImporter(directory: home.appendingPathComponent("Publications", isDirectory: true))
        stateDirectory = home.appendingPathComponent("ReaderState", isDirectory: true)
        readerStates = ReaderStateStore(directory: stateDirectory)
        sync = FolderSync(folder: folder, memoryURL: home.appendingPathComponent("sync.json"), deviceName: name, platform: "test")
    }

    @discardableResult
    func add(_ url: URL) throws -> EPUBPublication {
        let result = try importer.importPublication(from: url)
        editions[result.publication.id] = FolderSync.Edition(publication: result.publication, directory: result.directory)
        try store.saveBook(BookRecord(id: "epub:" + result.publication.id, title: result.publication.title, author: result.publication.authors.first, source: "stillleaf-epub"))
        return result.publication
    }

    func deleteBook(_ id: String) throws {
        try store.deleteBook(id)
        if let edition = FolderSync.editionID(ofBook: id), let held = editions.removeValue(forKey: edition) {
            try? FileManager.default.removeItem(at: held.directory)
            try? FileManager.default.removeItem(at: stateDirectory.appendingPathComponent(edition + ".json"))
        }
    }

    @discardableResult
    func pass(at now: Date, busy: Set<String> = []) throws -> FolderSync.Summary {
        try sync.sync(store: store, readerStates: readerStates, stateDirectory: stateDirectory, busy: busy, now: now,
                      editions: { Array(self.editions.values) },
                      importBook: { url in try self.add(url) },
                      deleteBook: { id in try self.deleteBook(id) },
                      deleteSession: { id in try self.store.deleteSession(id) })
    }

    func state(_ publication: EPUBPublication) throws -> [String: Any]? {
        try readerStates.load(publication: publication).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}


/// Runs the whole story, calling `failed` with a sentence for each expectation that does not hold.
func runFolderSyncScenario(failed: (String) -> Void) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("stillleaf-sync-smoke-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) {
        if (try? condition()) != true { failed(name) }
    }

    let fixtureScript = #"""
    import zipfile,sys,os
    root=sys.argv[1]
    container='<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
    opf='<package xmlns="http://www.idpf.org/2007/opf" version="3.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>The Shared Book</dc:title><dc:creator>A. Reader</dc:creator></metadata><manifest><item id="ch" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="ch"/></spine></package>'
    with zipfile.ZipFile(os.path.join(root,'shared.epub'),'w',compression=zipfile.ZIP_DEFLATED) as z:
     for p,d in [('mimetype','application/epub+zip'),('META-INF/container.xml',container),('EPUB/book.opf',opf),('EPUB/chapter.xhtml','<html><body><p>One page of a shared book.</p></body></html>')]:z.writestr(p,d)
    """#
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["python3", "-c", fixtureScript, root.path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { failed("python3 could not write the EPUB fixture"); return }
    let epub = root.appendingPathComponent("shared.epub")

    let folder = root.appendingPathComponent("Sync Folder", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let mac = try SyncScenarioDevice("Mac", in: root, folder: folder), phone = try SyncScenarioDevice("iPhone", in: root, folder: folder)
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
    func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    func interval(_ book: String, session: String, from: Double, to: Double) -> ReadingInterval {
        ReadingInterval(sessionID: session, bookID: book, start: at(from), end: at(to), duration: (to - from) * 60, timezoneID: "UTC", mode: .automatic)
    }
    /// The book's one chapter, by the path the importer gave it.
    var chapter = ""
    func locator(_ progression: Double) -> [String: Any] {
        ["href": chapter, "type": "application/xhtml+xml", "locations": ["progression": progression, "totalProgression": progression] as [String: Any]]
    }
    let preferences: [String: Any] = ["theme": "paper", "fontFamily": "serif", "fontSize": 1.2, "lineHeight": 1.6, "measure": 68]
    func save(_ device: SyncScenarioDevice, _ publication: EPUBPublication, revision: Int, position: Double, bookmarks: [[String: Any]], annotations: [[String: Any]],
              preferences: [String: Any] = preferences, savedAt: Date) throws {
        let state: [String: Any] = ["schemaVersion": 1, "editionId": publication.id, "revision": revision, "position": locator(position),
                                    "preferences": preferences, "bookmarks": bookmarks, "annotations": annotations]
        try device.readerStates.save(JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), publication: publication)
        // The file's time is when the reader last saved, which is how a device dates its place.
        try FileManager.default.setAttributes([.modificationDate: savedAt], ofItemAtPath: device.stateDirectory.appendingPathComponent(publication.id + ".json").path)
    }
    func bookmark(_ id: String, _ created: Date) -> [String: Any] { ["id": id, "locator": locator(0.1), "createdAt": stamp(created)] }
    func note(_ id: String, _ text: String, created: Date, updated: Date) -> [String: Any] {
        ["id": id, "locator": locator(0.2), "quote": "a shared book", "note": text, "color": "gold", "createdAt": stamp(created), "updatedAt": stamp(updated)]
    }
    func ids(_ state: [String: Any]?, _ key: String) -> Set<String> { Set((state?[key] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }) }
    func progression(_ state: [String: Any]?) -> Double? { ((state?["position"] as? [String: Any])?["locations"] as? [String: Any])?["progression"] as? Double }

    // 1. The Mac has a book, some reading, a place, a bookmark and a highlight. The phone has nothing.
    let book = try mac.add(epub)
    let bookID = "epub:" + book.id
    chapter = book.spine.first ?? ""
    try mac.store.appendInterval(interval(bookID, session: "mac-1", from: 0, to: 20))
    try mac.store.appendProgress(ProgressObservation(bookID: bookID, observedAt: at(20), fraction: 0.25, source: "stillleaf-epub-location", reliable: true))
    try save(mac, book, revision: 3, position: 0.25, bookmarks: [bookmark("b1", at(5))], annotations: [note("n1", "first thought", created: at(6), updated: at(6))], savedAt: at(20))
    let first = try mac.pass(at: at(21))
    expect(first.offeredBooks == 1 && first.devices.isEmpty, "the first device publishes its book and sees no others")
    expect(fm.fileExists(atPath: folder.appendingPathComponent("books/\(book.id).epub").path), "the book file is in the folder under its edition id")

    let arrival = try phone.pass(at: at(22))
    expect(arrival.importedBooks == 1 && arrival.journal.addedIntervals == 1 && arrival.journal.addedBooks == 1, "the phone receives the book and its history")
    expect(arrival.devices.map(\.name) == ["Mac"], "the phone sees the Mac by name")
    expect(try phone.store.archive().progress.count == 1, "progress observations cross, so the library shows the same place")
    let phoneBook = try phone.importer.importPublication(from: epub).publication
    expect(phoneBook.id == book.id, "the same file is the same edition on both devices")
    var phoneState = try phone.state(book)
    expect(progression(phoneState) == 0.25 && ids(phoneState, "bookmarks") == ["b1"] && ids(phoneState, "annotations") == ["n1"], "the phone opens at the Mac's place with its bookmark and highlight")

    // 2. The phone reads on, removes the bookmark, adds one, and rewrites the note. Appearance stays its own.
    try phone.store.appendInterval(interval(bookID, session: "phone-1", from: 30, to: 50))
    let phoneRevision = (phoneState?["revision"] as? NSNumber)?.intValue ?? 0
    var phoneLook = preferences; phoneLook["fontSize"] = 1.0; phoneLook["theme"] = "night"
    try save(phone, book, revision: phoneRevision + 4, position: 0.6, bookmarks: [bookmark("b2", at(40))],
             annotations: [note("n1", "second thought", created: at(6), updated: at(45))], preferences: phoneLook, savedAt: at(50))
    try phone.pass(at: at(51))
    let back = try mac.pass(at: at(52))
    var macState = try mac.state(book)
    expect(back.journal.addedIntervals == 1 && back.readerUpdates == [book.id], "the Mac receives the phone's reading and state")
    expect(progression(macState) == 0.6, "the place follows whichever device read last")
    expect(ids(macState, "bookmarks") == ["b2"], "a bookmark removed on the phone is removed on the Mac, and the new one arrives")
    expect(((macState?["annotations"] as? [[String: Any]])?.first?["note"] as? String) == "second thought", "the newer version of a highlight's note wins")
    expect((macState?["preferences"] as? [String: Any])?["theme"] as? String == "paper", "appearance is never taken from another device")

    // 3. A device that syncs without having read must not hand an old place back as if it were new.
    try save(mac, book, revision: ((macState?["revision"] as? NSNumber)?.intValue ?? 0) + 1, position: 0.8,
             bookmarks: macState?["bookmarks"] as? [[String: Any]] ?? [], annotations: macState?["annotations"] as? [[String: Any]] ?? [], savedAt: at(60))
    try phone.pass(at: at(70))   // the phone has not seen 0.8 yet and rewrites nothing newer
    try mac.pass(at: at(71))
    macState = try mac.state(book)
    expect(progression(macState) == 0.8, "a later sync by a device that did not read does not pull the place back")
    try phone.pass(at: at(72))
    phoneState = try phone.state(book)
    expect(progression(phoneState) == 0.8, "and the phone then moves up to the Mac's place")
    expect((phoneState?["preferences"] as? [String: Any])?["theme"] as? String == "night", "keeping its own appearance")

    // 4. A book that is open in a reader is published but not written under the reader.
    try save(mac, book, revision: ((macState?["revision"] as? NSNumber)?.intValue ?? 0) + 1, position: 0.9,
             bookmarks: macState?["bookmarks"] as? [[String: Any]] ?? [], annotations: macState?["annotations"] as? [[String: Any]] ?? [], savedAt: at(80))
    try mac.pass(at: at(81))
    let whileOpen = try phone.pass(at: at(82), busy: [book.id])
    expect(try whileOpen.readerUpdates.isEmpty && progression(phone.state(book)) == 0.8, "an open book's state is left alone")
    try phone.pass(at: at(83))
    expect(try progression(phone.state(book)) == 0.9, "and catches up once the reader has closed")

    // 5. Reading recorded on both devices for the same minutes: each keeps its own and leaves the other's out.
    try mac.store.appendInterval(interval(bookID, session: "mac-clash", from: 100, to: 120))
    try phone.store.appendInterval(interval(bookID, session: "phone-clash", from: 110, to: 130))
    try mac.pass(at: at(131))
    let clash = try phone.pass(at: at(132))
    expect(clash.journal.skippedSessions == ["mac-clash"], "overlapping reading from the other device is left out, not merged into double time")
    let macClash = try mac.pass(at: at(133))
    expect(macClash.journal.skippedSessions == ["phone-clash"], "on both devices")
    expect(try mac.store.effectiveIntervals().count == 3 && phone.store.effectiveIntervals().count == 3, "everything else is on both")

    // 6. A session deleted on the Mac is deleted on the phone and does not come back.
    try mac.store.deleteSession("mac-1")
    try mac.sync.recordDeletedSession("mac-1", at: at(140))
    try mac.pass(at: at(141))
    let deletion = try phone.pass(at: at(142))
    expect(deletion.deletedSessions == ["mac-1"], "the phone applies the Mac's deletion")
    try mac.pass(at: at(143))
    expect(try !mac.store.archive().intervals.contains { $0.sessionID == "mac-1" }, "the deleted session is not brought back by the phone's journal")
    expect(try !phone.store.archive().intervals.contains { $0.sessionID == "mac-1" }, "and is gone from the phone")

    // 7. With nothing new, a pass changes nothing and rewrites no journal file.
    let journalFile = folder.appendingPathComponent("devices/\(mac.sync.deviceID)/journal.json")
    let before = try fm.attributesOfItem(atPath: journalFile.path)[.modificationDate] as? Date
    let idle = try mac.pass(at: at(150))
    expect(!idle.changedLocalData && idle.warnings.isEmpty, "an idle pass changes nothing: \(idle)")
    expect((try fm.attributesOfItem(atPath: journalFile.path)[.modificationDate] as? Date) == before, "an idle pass does not rewrite the journal file")

    // 8. A book removed from one device with its history kept is not fetched again.
    if let held = phone.editions.removeValue(forKey: book.id) { try fm.removeItem(at: held.directory) }
    try phone.sync.declineEdition(book.id)
    let declined = try phone.pass(at: at(160))
    expect(declined.importedBooks == 0 && phone.editions.isEmpty, "a declined book stays off the device")
    expect(try phone.store.archive().books.contains { $0.id == bookID }, "while its history stays")

    // 9. Deleting a book and its history on the Mac removes it everywhere, file included.
    // A book's record carries the real time it was first seen, so its deletion is dated by the real clock too.
    try mac.deleteBook(bookID)
    try mac.sync.recordDeletedBook(bookID)
    expect(!fm.fileExists(atPath: folder.appendingPathComponent("books/\(book.id).epub").path), "the deleted book's file leaves the folder")
    try mac.pass(at: Date())
    let gone = try phone.pass(at: Date())
    expect(gone.deletedBooks == [bookID], "the phone deletes the book too")
    try mac.pass(at: Date())
    expect(try mac.store.archive().books.isEmpty && phone.store.archive().books.isEmpty, "and neither journal brings it back")
    expect(try mac.store.archive().intervals.isEmpty, "with its reading")

    // 10. Importing the same file again afterwards is a new start, not something the old deletion swallows.
    try mac.add(epub)
    try mac.store.appendInterval(interval(bookID, session: "mac-again", from: 300, to: 310))
    // The record is observed after the deletion; a real import stamps it with the current time, as here.
    try mac.pass(at: Date())
    let again = try phone.pass(at: Date())
    expect(again.journal.addedBooks == 1 && again.journal.addedIntervals == 1, "a book imported again after its deletion syncs as new: \(again)")

    // 11. A folder written by a newer format is refused rather than damaged.
    let future = root.appendingPathComponent("Future", isDirectory: true)
    try fm.createDirectory(at: future, withIntermediateDirectories: true)
    try Data(#"{"format":"stillleaf-sync","version":99}"#.utf8).write(to: future.appendingPathComponent("stillleaf-sync.json"))
    let stranger = try SyncScenarioDevice("Later", in: root, folder: future)
    do { _ = try stranger.pass(at: at(0)); expect(false, "a newer folder format must be refused") }
    catch { expect(error as? FolderSyncError == .newerFormat, "a newer folder format is refused with its own message") }

}

import Foundation
import CryptoKit
import BooksCore

public enum FolderSyncError: Error, LocalizedError, Equatable {
    case folderUnavailable
    case newerFormat
    case notASyncFolder

    public var errorDescription: String? {
        switch self {
        case .folderUnavailable: return "The sync folder can't be reached. Check that it still exists and that this device can open it."
        case .newerFormat: return "This sync folder was written by a newer version of Stillleaf. Update Stillleaf on this device to sync."
        case .notASyncFolder: return "That folder holds something else called a Stillleaf sync folder. Choose another folder."
        }
    }
}

/// Sync between a reader's own devices through a folder they choose, such as one in iCloud Drive.
///
/// There is no server and no account: whatever keeps the folder the same on each device carries the data.
/// Every device writes only inside its own subfolder, so two devices never write the same file and the
/// folder's own syncing has nothing to reconcile. Book files are named by the hash of their bytes, so two
/// devices that both add one write identical files.
///
///     <folder>/stillleaf-sync.json            what this folder is, and its format version
///     <folder>/devices/<device id>/device.json     the device's name
///     <folder>/devices/<device id>/journal.json    its whole journal, in the JSON export format
///     <folder>/devices/<device id>/tombstones.json what it has deleted
///     <folder>/devices/<device id>/reader/<edition>.json   its place, bookmarks and highlights in a book
///     <folder>/books/<edition>.epub           the books themselves
///
/// The host app drives one pass: `pull`, apply `deletions`, `mergeJournals`, import `missingBooks`,
/// `mergeReaderStates`, `offerBooks`, `push`. The steps are separate because the apps own their journal's
/// lifecycle (the tracker must be stopped around a merge) and their own way of importing a book.
public final class FolderSync {
    public static let formatVersion = 1
    /// How long a deletion is remembered. Any device that syncs at all applies it well within this.
    public static let tombstoneLifetime: TimeInterval = 400 * 86_400

    public struct Device: Codable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var platform: String
        public var updatedAt: Date
        public init(id: String, name: String, platform: String, updatedAt: Date) {
            self.id = id; self.name = name; self.platform = platform; self.updatedAt = updatedAt
        }
    }

    /// What this device remembers about one book between syncs, to notice what its reader removed or moved.
    public struct EditionMemory: Codable, Equatable {
        public var bookmarks: Set<String> = []
        public var annotations: Set<String> = []
        public var removedBookmarks: [String: Date] = [:]
        public var removedAnnotations: [String: Date] = [:]
        public var position: String?
        public var positionAt: Date?
        public init() {}
    }

    /// What this device remembers between syncs. It lives beside the journal, never in the sync folder.
    public struct Memory: Codable, Equatable {
        public var deviceID: String
        public var tombstones = SyncTombstones()
        /// Editions removed from this device on purpose with their history kept: not to be fetched again.
        public var declinedEditions: Set<String> = []
        public var editions: [String: EditionMemory] = [:]
        /// A digest of each other device's journal file as last merged. An unchanged file is not merged again,
        /// so an idle pass never touches the journal (or the tracker that sits on it).
        public var mergedJournals: [String: String] = [:]
        public var lastSync: Date?
        public init(deviceID: String = UUID().uuidString) { self.deviceID = deviceID }

        /// A memory file written by an older version lacks newer fields; only the device's identity is required.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            deviceID = try values.decode(String.self, forKey: .deviceID)
            tombstones = try values.decodeIfPresent(SyncTombstones.self, forKey: .tombstones) ?? SyncTombstones()
            declinedEditions = try values.decodeIfPresent(Set<String>.self, forKey: .declinedEditions) ?? []
            editions = try values.decodeIfPresent([String: EditionMemory].self, forKey: .editions) ?? [:]
            mergedJournals = try values.decodeIfPresent([String: String].self, forKey: .mergedJournals) ?? [:]
            lastSync = try values.decodeIfPresent(Date.self, forKey: .lastSync)
        }
    }

    public struct Edition {
        public let publication: EPUBPublication
        public let directory: URL
        public init(publication: EPUBPublication, directory: URL) { self.publication = publication; self.directory = directory }
    }

    /// Everything the other devices have published, read in one go.
    public struct Incoming {
        public var devices: [Device] = []
        /// Each device's journal file, still encoded: the store decodes and checks it when merging.
        public var journals: [(device: Device, data: Data)] = []
        public var tombstones = SyncTombstones()
        public var readerRecords: [String: [ReaderStateSync.Record]] = [:]
        /// Book files in the folder by edition id.
        public var books: [String: URL] = [:]
        /// Files the folder's own syncing has not brought to this device yet. They are asked for and read next time.
        public var waitingForDownload = 0
        public var warnings: [String] = []
    }

    public let folder: URL
    public private(set) var memory: Memory
    private let memoryURL: URL
    private let deviceName: String
    private let platform: String
    private let fm = FileManager.default
    private var outgoingRecords: [String: ReaderStateSync.Record] = [:]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    /// `memoryURL` is a file in the app's own storage. A device keeps its identity for as long as that file lives.
    public init(folder: URL, memoryURL: URL, deviceName: String, platform: String) {
        self.folder = folder
        self.memoryURL = memoryURL
        self.deviceName = deviceName
        self.platform = platform
        memory = (try? Data(contentsOf: memoryURL)).flatMap { try? Self.decoder.decode(Memory.self, from: $0) } ?? Memory()
    }

    public var deviceID: String { memory.deviceID }
    private var devicesFolder: URL { folder.appendingPathComponent("devices", isDirectory: true) }
    private var ownFolder: URL { devicesFolder.appendingPathComponent(memory.deviceID, isDirectory: true) }
    private var booksFolder: URL { folder.appendingPathComponent("books", isDirectory: true) }

    /// What one pass did, for the app to show and act on.
    public struct Summary: Equatable {
        public var devices: [Device] = []
        public var journal = SyncMergeReport()
        public var deletedSessions: [String] = []
        public var deletedBooks: [String] = []
        public var importedBooks = 0
        public var offeredBooks = 0
        /// Editions whose saved place, bookmarks or highlights changed.
        public var readerUpdates: [String] = []
        public var waitingForDownload = 0
        public var warnings: [String] = []
        public init() {}
        /// True when the pass changed anything on this device.
        public var changedLocalData: Bool {
            journal.changedAnything || !deletedSessions.isEmpty || !deletedBooks.isEmpty || importedBooks > 0 || !readerUpdates.isEmpty
        }
    }

    /// One whole pass, in the order that keeps every step consistent: read the folder, apply the other
    /// devices' deletions, merge their journals, fetch their books, merge reader state, then publish.
    ///
    /// The closures are the host's own ways of doing things. `editions` lists the books on this device (asked
    /// again after imports). `willChangeJournal` is called once, just before the journal is first changed, and
    /// not at all on a pass with nothing to merge: the apps stop their tracker there. The delete closures
    /// remove a book or a session as the app does elsewhere; one that throws is reported and tried again on
    /// the next pass. With `offersBooks` false the host copies its books into the folder itself
    /// (`offerBooks`), which it may do away from the main thread.
    public func sync(store: ReadingStore, readerStates: ReaderStateStore, stateDirectory: URL, busy: Set<String> = [], now: Date = Date(),
                     offersBooks: Bool = true, editions: () -> [Edition], willChangeJournal: () throws -> Void = {},
                     importBook: (URL) throws -> Void,
                     deleteBook: (String) throws -> Void, deleteSession: (String) throws -> Void) throws -> Summary {
        var summary = Summary()
        let incoming = try pull()
        summary.devices = incoming.devices
        summary.waitingForDownload = incoming.waitingForDownload
        summary.warnings = incoming.warnings
        let pending = try deletions(from: incoming, in: store.archive())
        let changed = incoming.journals.filter { memory.mergedJournals[$0.device.id] != Self.digest($0.data) }
        if !pending.sessions.isEmpty || !pending.books.isEmpty || !changed.isEmpty { try willChangeJournal() }
        for id in pending.sessions {
            do { try deleteSession(id); summary.deletedSessions.append(id) }
            catch { summary.warnings.append("A session deleted on another device could not be deleted here yet: \(error.localizedDescription)") }
        }
        for id in pending.books {
            do { try deleteBook(id); summary.deletedBooks.append(id) }
            catch { summary.warnings.append("A book deleted on another device could not be deleted here yet: \(error.localizedDescription)") }
        }
        for (device, data) in changed {
            do {
                summary.journal.add(try store.mergeSynced(try store.decodeArchive(data), tombstones: memory.tombstones))
                memory.mergedJournals[device.id] = Self.digest(data)
            } catch { summary.warnings.append("\(device.name)'s journal could not be merged: \(Self.describe(error))") }
        }
        for url in missingBooks(incoming, having: Set(editions().map(\.publication.id))) {
            do { try importBook(url); summary.importedBooks += 1 }
            catch { summary.warnings.append("A book in the sync folder could not be added: \(error.localizedDescription)") }
        }
        let current = editions()
        summary.readerUpdates = try mergeReaderStates(incoming, editions: current, store: readerStates, stateDirectory: stateDirectory, busy: busy, now: now)
        if offersBooks { summary.offeredBooks = try offerBooks(current) }
        try push(store: store, now: now)
        return summary
    }

    // MARK: - Things the host records as they happen

    public func recordDeletedSession(_ id: String, at date: Date = Date()) throws {
        memory.tombstones.deleteSession(id, at: date)
        try saveMemory()
    }

    /// The reader deleted a book and its history. Its file leaves the folder too, so no device offers it again.
    public func recordDeletedBook(_ bookID: String, at date: Date = Date()) throws {
        memory.tombstones.deleteBook(bookID, at: date)
        if let edition = Self.editionID(ofBook: bookID) {
            memory.editions[edition] = nil
            try? fm.removeItem(at: booksFolder.appendingPathComponent(edition + ".epub"))
            try? fm.removeItem(at: ownFolder.appendingPathComponent("reader", isDirectory: true).appendingPathComponent(edition + ".json"))
        }
        try saveMemory()
    }

    /// The reader removed a book's file from this device but kept its history: do not fetch it again.
    public func declineEdition(_ editionID: String) throws {
        memory.declinedEditions.insert(editionID)
        memory.editions[editionID] = nil
        try saveMemory()
    }

    /// This device no longer holds these books' reader state (all of them when nil). What it remembered of
    /// their bookmarks and highlights must go too: a book that comes back empty has not had them removed.
    public func forgetEditions(_ editionIDs: [String]? = nil) throws {
        if let editionIDs { for id in editionIDs { memory.editions[id] = nil } } else { memory.editions = [:]; memory.mergedJournals = [:] }
        try saveMemory()
    }

    /// This device's journal was replaced or lost rows (a restore, an import): merge every device's journal afresh.
    public func forgetMergedJournals() throws {
        memory.mergedJournals = [:]
        try saveMemory()
    }

    /// The reader imported the book here again themselves.
    public func acceptEdition(_ editionID: String) throws {
        guard memory.declinedEditions.remove(editionID) != nil else { return }
        try saveMemory()
    }

    // MARK: - Reading the folder

    /// Makes the folder a sync folder if it is not one yet, then reads what every other device has published.
    public func pull() throws -> Incoming {
        try prepareFolder()
        var incoming = Incoming()
        for entry in listing(devicesFolder) where entry.hasDirectoryPath && entry.lastPathComponent != memory.deviceID {
            let id = entry.lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            let device = read(Device.self, entry.appendingPathComponent("device.json"), &incoming)
                ?? Device(id: id, name: "Another device", platform: "", updatedAt: .distantPast)
            guard device.id == id else { incoming.warnings.append("A device folder does not match the device it names."); continue }
            incoming.devices.append(device)
            if let journal = data(entry.appendingPathComponent("journal.json"), &incoming) { incoming.journals.append((device, journal)) }
            if let tombstones = read(SyncTombstones.self, entry.appendingPathComponent("tombstones.json"), &incoming) { incoming.tombstones.merge(tombstones) }
            for file in listing(entry.appendingPathComponent("reader", isDirectory: true), &incoming) where file.pathExtension == "json" {
                guard let contents = data(file, &incoming), let record = try? ReaderStateSync.Record.decode(contents),
                      record.editionID == file.deletingPathExtension().lastPathComponent else { continue }
                incoming.readerRecords[record.editionID, default: []].append(record)
            }
        }
        for file in listing(booksFolder, &incoming) where file.pathExtension == "epub" {
            let edition = file.deletingPathExtension().lastPathComponent
            if Self.isEditionID(edition) { incoming.books[edition] = file }
        }
        return incoming
    }

    /// Deletions other devices made that this device still holds: the host removes them in its own way (a book
    /// takes its files and reader state with it) and they are remembered here so nothing brings them back.
    public func deletions(from incoming: Incoming, in archive: HistoryArchive) throws -> (sessions: [String], books: [String]) {
        let localSessions = Set((archive.intervals + archive.corrections.flatMap(\.replacements)).map(\.sessionID))
        let sessions = incoming.tombstones.sessions.keys.filter(localSessions.contains).sorted()
        let books = archive.books.filter(incoming.tombstones.covers).map(\.id).sorted()
        if memory.tombstones.merge(incoming.tombstones) { try saveMemory() }
        return (sessions, books)
    }

    /// Merges every other device's journal into this one. A journal that cannot be read or reconciled is
    /// reported and left for the next pass; the others still merge.
    public func mergeJournals(_ incoming: Incoming, into store: ReadingStore) -> (report: SyncMergeReport, warnings: [String]) {
        var report = SyncMergeReport(), warnings: [String] = []
        for (device, data) in incoming.journals {
            do {
                report.add(try store.mergeSynced(try store.decodeArchive(data), tombstones: memory.tombstones))
                memory.mergedJournals[device.id] = Self.digest(data)
            } catch { warnings.append("\(device.name)'s journal could not be merged: \(Self.describe(error))") }
        }
        return (report, warnings)
    }

    /// Book files in the folder that this device does not have, has not declined and has not deleted.
    public func missingBooks(_ incoming: Incoming, having editions: Set<String>) -> [URL] {
        incoming.books.filter { edition, _ in
            !editions.contains(edition) && !memory.declinedEditions.contains(edition) && memory.tombstones.books["epub:" + edition] == nil
        }.sorted { $0.key < $1.key }.map(\.value)
    }

    // MARK: - Reader state

    /// Brings each book's place, bookmarks and highlights up to date from the other devices, and works out what
    /// this device will publish for it. An edition in `busy` is open in a reader right now: it is published as
    /// it stands and left alone, because the reader would write over anything saved under it.
    /// Returns the editions whose saved state changed.
    @discardableResult
    public func mergeReaderStates(_ incoming: Incoming, editions: [Edition], store: ReaderStateStore, stateDirectory: URL,
                                  busy: Set<String> = [], now: Date = Date()) throws -> [String] {
        var updated: [String] = []
        outgoingRecords = [:]
        let cutoff = now.addingTimeInterval(-Self.tombstoneLifetime)
        for edition in editions {
            let id = edition.publication.id
            var memo = memory.editions[id] ?? EditionMemory()
            let localData = try? store.load(publication: edition.publication)
            if let localData, let contents = ReaderStateSync.contents(of: localData) {
                for gone in memo.bookmarks.subtracting(contents.bookmarks) { memo.removedBookmarks[gone] = now }
                for gone in memo.annotations.subtracting(contents.annotations) { memo.removedAnnotations[gone] = now }
                if contents.position != memo.position {
                    memo.position = contents.position
                    let saved = (try? fm.attributesOfItem(atPath: stateDirectory.appendingPathComponent(id + ".json").path))?[.modificationDate] as? Date
                    memo.positionAt = min(saved ?? now, now)
                }
                memo.bookmarks = contents.bookmarks
                memo.annotations = contents.annotations
            }
            memo.removedBookmarks = memo.removedBookmarks.filter { $0.value >= cutoff }
            memo.removedAnnotations = memo.removedAnnotations.filter { $0.value >= cutoff }
            let local = localData.map {
                ReaderStateSync.Record(editionID: id, state: $0, positionAt: memo.positionAt,
                                       removedBookmarks: memo.removedBookmarks, removedAnnotations: memo.removedAnnotations)
            }
            let remotes = incoming.readerRecords[id] ?? []
            if busy.contains(id) || remotes.isEmpty {
                outgoingRecords[id] = local
            } else if let merged = ReaderStateSync.merge(local: local, remotes: remotes, publication: edition.publication) {
                if merged.changed {
                    try store.save(merged.record.state, publication: edition.publication)
                    updated.append(id)
                }
                if let contents = ReaderStateSync.contents(of: merged.record.state) {
                    memo.bookmarks = contents.bookmarks
                    memo.annotations = contents.annotations
                    memo.position = contents.position
                }
                memo.positionAt = merged.record.positionAt
                memo.removedBookmarks = merged.record.removedBookmarks.filter { $0.value >= cutoff }
                memo.removedAnnotations = merged.record.removedAnnotations.filter { $0.value >= cutoff }
                outgoingRecords[id] = merged.record
            } else {
                outgoingRecords[id] = local
            }
            memory.editions[id] = memo
        }
        try saveMemory()
        return updated
    }

    // MARK: - Writing the folder

    /// Puts this device's books in the folder for the others. Returns how many were added.
    /// Copies can be large; the host may call this away from the main thread.
    @discardableResult
    public func offerBooks(_ editions: [Edition]) throws -> Int {
        try prepareFolder()
        try fm.createDirectory(at: booksFolder, withIntermediateDirectories: true)
        var added = 0
        for edition in editions {
            let id = edition.publication.id
            let source = edition.directory.appendingPathComponent("original.epub")
            let destination = booksFolder.appendingPathComponent(id + ".epub")
            guard Self.isEditionID(id), memory.tombstones.books["epub:" + id] == nil, fm.fileExists(atPath: source.path),
                  !fm.fileExists(atPath: destination.path), !fm.fileExists(atPath: Self.placeholder(for: destination).path) else { continue }
            // A name ending in .tmp is one iCloud Drive does not upload, so no device sees half a book.
            let partial = booksFolder.appendingPathComponent(id + "-" + memory.deviceID + ".epub.tmp")
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: source, to: partial)
            do { try fm.moveItem(at: partial, to: destination) }
            catch {
                try? fm.removeItem(at: partial)
                if !fm.fileExists(atPath: destination.path) { throw error }
            }
            added += 1
        }
        return added
    }

    /// Publishes this device's journal, deletions and reader records. Call after the merges, so what is
    /// published already includes what was just learned.
    public func push(store: ReadingStore, now: Date = Date()) throws {
        try prepareFolder()
        let reader = ownFolder.appendingPathComponent("reader", isDirectory: true)
        try fm.createDirectory(at: reader, withIntermediateDirectories: true)
        memory.tombstones.prune(before: now.addingTimeInterval(-Self.tombstoneLifetime))
        try write(Self.encoder.encode(Device(id: memory.deviceID, name: deviceName, platform: platform, updatedAt: now)), to: ownFolder.appendingPathComponent("device.json"))
        try write(Self.encoder.encode(memory.tombstones), to: ownFolder.appendingPathComponent("tombstones.json"))
        let journal = ownFolder.appendingPathComponent("journal.json")
        if let data = try store.encodedArchive(unlessSameAs: try? Data(contentsOf: journal)) { try write(data, to: journal) }
        for (edition, record) in outgoingRecords {
            try write(record.encoded(), to: reader.appendingPathComponent(edition + ".json"))
        }
        // A record for a book this device no longer has would keep publishing an old place.
        for file in listing(reader) where file.pathExtension == "json" && outgoingRecords[file.deletingPathExtension().lastPathComponent] == nil {
            try? fm.removeItem(at: file)
        }
        memory.lastSync = now
        try saveMemory()
    }

    /// Takes this device out of the folder: its journal copy, deletions and reader records. Books stay for the others.
    public func removeOwnData() throws {
        if fm.fileExists(atPath: ownFolder.path) { try fm.removeItem(at: ownFolder) }
    }

    // MARK: - Files

    private func prepareFolder() throws {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw FolderSyncError.folderUnavailable }
        let marker = folder.appendingPathComponent("stillleaf-sync.json")
        if fm.fileExists(atPath: Self.placeholder(for: marker).path) {
            try? fm.startDownloadingUbiquitousItem(at: marker)
        } else if let data = try? Data(contentsOf: marker) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["format"] as? String == "stillleaf-sync",
                  let version = (object["version"] as? NSNumber)?.intValue else { throw FolderSyncError.notASyncFolder }
            guard version <= Self.formatVersion else { throw FolderSyncError.newerFormat }
        } else {
            let object: [String: Any] = ["format": "stillleaf-sync", "version": Self.formatVersion]
            try write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: marker)
        }
        try fm.createDirectory(at: ownFolder, withIntermediateDirectories: true)
    }

    /// The visible entries of a folder. A file its syncing has not downloaded yet shows as a hidden
    /// `.name.icloud` placeholder: it is asked for and counted, and read on a later pass.
    private func listing(_ directory: URL) -> [URL] {
        var ignored = Incoming()
        return listing(directory, &ignored)
    }

    private func listing(_ directory: URL, _ incoming: inout Incoming) -> [URL] {
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [URL] = []
        for name in names.sorted() {
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = directory.appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
                try? fm.startDownloadingUbiquitousItem(at: real)
                incoming.waitingForDownload += 1
            } else if !name.hasPrefix("."), !name.hasSuffix(".tmp") {
                var isDirectory: ObjCBool = false
                let url = directory.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    result.append(isDirectory.boolValue ? directory.appendingPathComponent(name, isDirectory: true) : url)
                }
            }
        }
        return result
    }

    private func data(_ url: URL, _ incoming: inout Incoming) -> Data? {
        if fm.fileExists(atPath: Self.placeholder(for: url).path) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            incoming.waitingForDownload += 1
            return nil
        }
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue <= 256 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL, _ incoming: inout Incoming) -> T? {
        data(url, &incoming).flatMap { try? Self.decoder.decode(type, from: $0) }
    }

    private func write(_ data: Data, to url: URL) throws {
        // Unchanged files are left alone, so the folder's syncing has nothing to upload.
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
    }

    private func saveMemory() throws {
        try fm.createDirectory(at: memoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(memory).write(to: memoryURL, options: .atomic)
    }

    private static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    static func isEditionID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// The edition a journal book id names, when the book is an imported EPUB.
    public static func editionID(ofBook bookID: String) -> String? {
        guard bookID.hasPrefix("epub:") else { return nil }
        let edition = String(bookID.dropFirst(5))
        return isEditionID(edition) ? edition : nil
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ error: Error) -> String {
        (error as? ReadingStoreError)?.description ?? error.localizedDescription
    }
}

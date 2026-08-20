import AppKit
import BooksCore
import BooksPlatform
import UniformTypeIdentifiers

/// App-owned import lifecycle. All ZIP/file work runs on one background queue;
/// publication registration is delivered back to the main-actor journal owner.
@MainActor
final class EPUBLibraryController: ObservableObject {
    @Published private(set) var queue = EPUBImportQueue()
    @Published private(set) var publications: [String: EPUBPublication] = [:]
    @Published private(set) var recoveryError: String?
    @Published private(set) var removingIDs = Set<String>()
    let directory: URL
    var register: ((EPUBPublication, URL) throws -> Void)?
    var presentLibrary: (() -> Void)?
    /// A fresh import from a file the reader chose; the journal may offer to link it.
    var didImport: ((EPUBPublication) -> Void)?
    /// Every queued import has finished.
    var didFinishQueue: (() -> Void)?
    /// Startup recovery has registered the imported library.
    var didRecover: (() -> Void)?
    private let importer: EPUBPublicationImporter
    private let worker = DispatchQueue(label: "Stillleaf.epub-import", qos: .userInitiated)

    init(directory: URL) {
        self.directory = directory
        importer = EPUBPublicationImporter(directory: directory)
    }

    func recover() {
        let importer = self.importer
        worker.async { [weak self] in
            let result = Result { try importer.recoverLibrary() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let recovery = try result.get()
                    var warnings = recovery.warnings
                    var failures = recovery.failedCount
                    for item in recovery.publications {
                        do {
                            try self.register?(item.publication, item.directory)
                            self.publications[item.publication.id] = item.publication
                        } catch {
                            failures += 1
                            if warnings.count < 20 { warnings.append(String("Edition \(item.publication.id.prefix(12)): \(error.localizedDescription)".prefix(512))) }
                        }
                    }
                    self.recoveryError = failures == 0 ? nil : "\(failures) imported books could not be restored. Healthy books remain available. " + warnings.joined(separator: "\n")
                } catch { self.recoveryError = "Imported books could not be inspected: \(error.localizedDescription)" }
                self.didRecover?()
            }
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Import EPUBs into your Library"
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor [weak self] in self?.enqueue(panel.urls) }
        }
    }

    func enqueue(_ urls: [URL]) {
        queue.enqueue(urls)
        if queue.consumeLibraryPresentation() { presentLibrary?() }
        drain()
    }

    /// Imports the copy Apple Books keeps of a book the reader added there themselves.
    /// Store purchases are refused by the importer's protection check.
    func importFromAppleBooks(assetID: String, completion: @escaping (Result<EPUBPublication, Error>) -> Void) {
        let importer = self.importer
        worker.async { [weak self] in
            let outcome = Result { () throws -> EPUBPublicationImportResult in
                guard let location = try BooksCatalog().assetURL(forAssetID: assetID) else {
                    throw EPUBImportError.invalid("Apple Books does not list a file for this book.")
                }
                guard FileManager.default.fileExists(atPath: location.path) else {
                    throw EPUBImportError.invalid("This book is not downloaded on this Mac. Open it once in Apple Books, then try again.")
                }
                guard ["epub"].contains(location.pathExtension.lowercased()) else {
                    throw EPUBImportError.invalid("Only EPUB books can be read in Stillleaf. Keep reading this one in Apple Books.")
                }
                return try importer.importPublication(from: location)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try outcome.get()
                    try self.register?(result.publication, result.directory)
                    self.publications[result.publication.id] = result.publication
                    completion(.success(result.publication))
                } catch { completion(.failure(error)) }
            }
        }
    }

    func cancelPending() { queue.cancelPending() }
    func reserveRemoval(_ id: String) -> Bool { removingIDs.insert(id).inserted }
    func cancelRemoval(_ id: String) { removingIDs.remove(id) }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            var failures = max(0, providers.count - EPUBImportQueue.maximumItems)
            for provider in providers.prefix(EPUBImportQueue.maximumItems) {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                        if let url = value as? URL { continuation.resume(returning: url) }
                        else if let data = value as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url { urls.append(url) } else { failures += 1 }
            }
            if failures > 0 { recoveryError = "\(failures) dropped items could not be queued. Use Import EPUBs for those files; batches support up to 1,000 files." }
            enqueue(urls)
        }
        return true
    }

    func remove(publicationID: String, keepingOriginalAt destination: URL?, completion: @escaping () -> Void) {
        let root = directory
        worker.async { [weak self] in
            let outcome = Result { try EPUBAssetRemoval(directory: root).remove(publicationID: publicationID, keepingOriginalAt: destination) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.removingIDs.remove(publicationID)
                do {
                    _ = try outcome.get()
                    self.publications.removeValue(forKey: publicationID)
                    self.recoveryError = nil
                    completion()
                } catch { self.recoveryError = error.localizedDescription }
            }
        }
    }

    private func drain() {
        guard let item = queue.takeNext() else { if !queue.isBusy { didFinishQueue?() }; return }
        let importer = self.importer
        worker.async { [weak self] in
            let outcome = Result { try importer.importPublication(from: item.url) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try outcome.get()
                    try self.register?(result.publication, result.directory)
                    self.publications[result.publication.id] = result.publication
                    self.queue.finish(id: item.id, result: result.alreadyImported
                        ? .alreadyImported(publicationID: result.publication.id)
                        : .imported(publicationID: result.publication.id))
                    self.didImport?(result.publication)
                } catch {
                    // The receipt remains available for recovery if journal
                    // registration failed after the file transaction committed.
                    self.queue.finish(id: item.id, result: .failed(message: error.localizedDescription))
                }
                self.drain()
            }
        }
    }
}

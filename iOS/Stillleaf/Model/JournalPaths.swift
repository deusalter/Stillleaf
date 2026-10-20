import Foundation

/// Where the journal lives. The layout matches the Mac's support folder, so the
/// same `ReadingStore`, importer and reader-state code read it unchanged.
struct JournalPaths {
    let root: URL

    var history: URL { root.appendingPathComponent("history.sqlite") }
    var publications: URL { root.appendingPathComponent("Publications", isDirectory: true) }
    var readerState: URL { root.appendingPathComponent("ReaderState", isDirectory: true) }
    /// Short-lived export files handed to the system file exporter.
    var exports: URL { root.appendingPathComponent("Exports", isDirectory: true) }

    /// `Application Support/Stillleaf` inside the app container. It is included in
    /// device backups and never exposed in the Files app.
    static func applicationSupport() throws -> JournalPaths {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return JournalPaths(root: base.appendingPathComponent("Stillleaf", isDirectory: true))
    }

    func prepare() throws {
        for directory in [root, publications, readerState] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    /// Creates the folders and returns paths through the real directory. On devices the app
    /// container is reached through the `/var` symbolic link, which edition removal refuses to
    /// cross. `URL.resolvingSymlinksInPath()` would strip `/private` again, so use realpath(3).
    func prepared() throws -> JournalPaths {
        try prepare()
        guard let resolved = realpath(root.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        let canonical = JournalPaths(root: URL(fileURLWithPath: String(cString: resolved), isDirectory: true))
        try canonical.prepare()
        return canonical
    }
}

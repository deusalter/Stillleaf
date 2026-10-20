import Foundation
import BooksCore

/// Everything a host needs to open one edition in the shared renderer: the session resource
/// map and the JSON input for `window.StillleafReader.open(...)`. The Mac and iOS readers
/// build it here so both hand the renderer identical input.
public struct ReaderLaunch {
    public let resources: ReaderResourceMap
    public let payload: String

    /// Loads the first renderer build among `shellCandidates` (folders holding `index.html`) into
    /// memory, maps the edition's files for on-demand reads, and restores saved reader state.
    /// Performs file I/O; call off the main thread.
    public static func prepare(publication: EPUBPublication, directory: URL, shellCandidates: [URL],
                               stateDirectory: URL) throws -> ReaderLaunch {
        let fm = FileManager.default
        // Resolve the folder first: SwiftPM's .build/release is a symlink, and the
        // enumerator reports resolved paths, so an unresolved prefix yields wrong keys.
        guard let found = shellCandidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("index.html").path) }) else {
            throw EPUBImportError.invalid("Reader files are missing from this local build.")
        }
        let shell = found.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fm.enumerator(at: shell, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw EPUBImportError.invalid("Reader files are missing from this local build.")
        }
        var assets: [String: ReaderResourceMap.Asset] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw EPUBImportError.invalid("Invalid reader build resource.") }
            guard values.isRegularFile == true else { continue }
            let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard filePath.hasPrefix(shell.path + "/") else { throw EPUBImportError.invalid("Invalid reader build resource.") }
            let path = String(filePath.dropFirst(shell.path.count + 1))
            let mime: String
            switch url.pathExtension {
            case "html": mime = "text/html"; case "js": mime = "application/javascript"; case "css": mime = "text/css"
            case "json", "map": mime = "application/json"; case "svg": mime = "image/svg+xml"; case "png": mime = "image/png"
            case "woff2": mime = "font/woff2"; default: mime = "application/octet-stream"
            }
            assets[path] = .init(data: try Data(contentsOf: url), mimeType: mime)
        }
        // Publication bytes stay on disk. The renderer fetches each file through the
        // session scheme when a chapter needs it, instead of receiving the whole book.
        let resourceRoot = directory.appendingPathComponent("resources", isDirectory: true)
        let rootPath = resourceRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var total = 0
        let files: [ReaderResourceMap.FileAsset] = try publication.resources.map { item -> ReaderResourceMap.FileAsset in
            // Imported paths were validated at import; still confirm each file sits inside this edition.
            let file = resourceRoot.appendingPathComponent(item.path).standardizedFileURL
            guard !item.path.hasPrefix("/"), file.resolvingSymlinksInPath().path.hasPrefix(rootPath),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
                throw EPUBImportError.invalid("A book resource is missing. Import the book again.")
            }
            total += size
            guard size <= ReaderResourceMap.maximumFileAssetBytes, total <= 256 * 1_024 * 1_024 else { throw EPUBImportError.invalid("Book resources exceed the reader size limit.") }
            // The renderer decides from the manifest type; the response header only needs to be well formed.
            let served = ReaderResourceMap.isValidMIMEType(item.mediaType) ? item.mediaType : "application/octet-stream"
            return ReaderResourceMap.FileAsset(file: file, mimeType: served, byteCount: size)
        }
        let map = try ReaderResourceMap(resources: assets, files: files)
        guard map.url(for: "index.html") != nil else { throw EPUBImportError.invalid("Reader files are missing from this local build.") }
        let resources: [[String: Any]] = try publication.resources.enumerated().map { index, item -> [String: Any] in
            guard let url = map.fileURL(at: index) else { throw EPUBImportError.invalid("Book resources could not be prepared.") }
            return ["href": item.path, "type": item.mediaType, "url": url.absoluteString, "size": files[index].byteCount]
        }
        var input: [String: Any] = ["editionId": publication.id, "title": publication.title, "creators": publication.authors,
            "layout": publication.layout ?? "reflowable", "canReturnToLibrary": true,
            // Continuous reads as one scroll across chapters; without this, scroll mode stops at each chapter end.
            "experimentalContinuous": true, "contentProgress": true,
            "readingOrder": publication.spine.map { path in ["href": path, "type": publication.resources.first(where: { $0.path == path })?.mediaType ?? "application/xhtml+xml"] }, "resources": resources]
        for (key, links) in [("toc", publication.toc), ("landmarks", publication.landmarks), ("pageList", publication.pageList)] {
            if let links { input[key] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(links)) }
        }
        if let language = publication.languages?.first { input["language"] = language }
        if let direction = publication.readingProgression { input["readingProgression"] = direction }
        if let data = try ReaderStateStore(directory: stateDirectory).load(publication: publication) {
            input["state"] = try JSONSerialization.jsonObject(with: data)
        }
        return ReaderLaunch(resources: map, payload: String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self))
    }
}

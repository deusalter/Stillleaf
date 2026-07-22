import Foundation

public enum EPUBImportState: String, Equatable { case queued, importing, imported, duplicate, failed, cancelled }

public enum EPUBImportResult: Equatable {
    case imported(publicationID: String)
    case alreadyImported(publicationID: String)
    case failed(message: String)
    case cancelled
}

public struct EPUBImportItem: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public fileprivate(set) var state: EPUBImportState
    public fileprivate(set) var publicationID: String?
    public fileprivate(set) var message: String?
}

public struct EPUBImportSummary: Equatable {
    public var imported = 0
    public var duplicates = 0
    public var failed = 0
    public var cancelled = 0
    public var remaining = 0
}

/// Library-first import coordination shared by picker/drop/OS-open entry points.
/// This value type never opens a reader or starts tracking. Hosts serialize access
/// and consume one Library presentation request using their existing window.
public struct EPUBImportQueue {
    public private(set) var items: [EPUBImportItem] = []
    public private(set) var rejectedOverflowCount = 0
    private var presentationPending = false
    public static let maximumItems = 1_000
    public init() {}

    public var isBusy: Bool { items.contains { $0.state == .queued || $0.state == .importing } }
    public var summary: EPUBImportSummary {
        var result = EPUBImportSummary()
        for item in items {
            switch item.state {
            case .imported: result.imported += 1
            case .duplicate: result.duplicates += 1
            case .failed: result.failed += 1
            case .cancelled: result.cancelled += 1
            case .queued, .importing: result.remaining += 1
            }
        }
        result.failed += rejectedOverflowCount
        return result
    }

    public mutating func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if !isBusy { items.removeAll(keepingCapacity: true); rejectedOverflowCount = 0 }
        presentationPending = true
        var known = Set(items.map { $0.url })
        for original in urls {
            let url = original.isFileURL ? original.standardizedFileURL : original
            guard known.insert(url).inserted else { continue }
            guard items.count < Self.maximumItems else { rejectedOverflowCount += 1; continue }
            let supported = url.isFileURL && url.pathExtension.lowercased() == "epub"
            items.append(EPUBImportItem(id: UUID(), url: url, state: supported ? .queued : .failed,
                publicationID: nil, message: supported ? nil : "Choose a local EPUB file."))
        }
    }

    public mutating func consumeLibraryPresentation() -> Bool {
        let pending = presentationPending
        presentationPending = false
        return pending
    }

    public mutating func takeNext() -> EPUBImportItem? {
        guard !items.contains(where: { $0.state == .importing }),
              let index = items.firstIndex(where: { $0.state == .queued }) else { return nil }
        items[index].state = .importing
        return items[index]
    }

    public mutating func finish(id: UUID, result: EPUBImportResult) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.state == .importing }) else { return }
        switch result {
        case .imported(let id): items[index].state = .imported; items[index].publicationID = id
        case .alreadyImported(let id): items[index].state = .duplicate; items[index].publicationID = id
        case .failed(let message): items[index].state = .failed; items[index].message = message
        case .cancelled: items[index].state = .cancelled
        }
    }

    /// The host may separately cancel its active importer. An in-flight result
    /// stays in-flight until the importer reports the actual durable outcome.
    public mutating func cancelPending() {
        for index in items.indices where items[index].state == .queued { items[index].state = .cancelled }
    }
}

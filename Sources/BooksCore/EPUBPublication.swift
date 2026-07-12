import Foundation

/// An imported edition. Paths are validated package-relative names, never external URLs.
public struct EPUBPublication: Codable, Equatable {
    public var id: String
    public var title: String
    public var authors: [String]
    public var packagePath: String
    public var resources: [EPUBResource]
    public var spine: [String]
    public var coverPath: String?
    public var warnings: [String]
    public var layout: String?
    public var languages: [String]?
    public var readingProgression: String?
    public var toc: [EPUBNavigationLink]?
    public var landmarks: [EPUBNavigationLink]?
    public var pageList: [EPUBNavigationLink]?
    public init(id: String, title: String, authors: [String], packagePath: String, resources: [EPUBResource], spine: [String], coverPath: String?, warnings: [String], layout: String? = nil, languages: [String]? = nil, readingProgression: String? = nil, toc: [EPUBNavigationLink]? = nil, landmarks: [EPUBNavigationLink]? = nil, pageList: [EPUBNavigationLink]? = nil) {
        self.id = id; self.title = title; self.authors = authors; self.packagePath = packagePath
        self.resources = resources; self.spine = spine; self.coverPath = coverPath; self.warnings = warnings
        self.layout = layout; self.languages = languages; self.readingProgression = readingProgression
        self.toc = toc; self.landmarks = landmarks; self.pageList = pageList
    }
}
public struct EPUBResource: Codable, Equatable {
    public var id: String
    public var path: String
    public var mediaType: String
    public init(id: String, path: String, mediaType: String) { self.id = id; self.path = path; self.mediaType = mediaType }
}

/// Readium-compatible local navigation link; href may include a fragment.
public struct EPUBNavigationLink: Codable, Equatable {
    public var href: String
    public var title: String
    public var children: [EPUBNavigationLink]?
    public init(href: String, title: String, children: [EPUBNavigationLink]? = nil) {
        self.href = href; self.title = title; self.children = children
    }
}

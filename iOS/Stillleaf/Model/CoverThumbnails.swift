import Foundation
import ImageIO
import CoreGraphics

/// Downsampled covers read straight from an imported edition's own cover image.
/// No absolute cover paths are stored: app-container paths change across restores.
final class CoverThumbnails {
    static let shared = CoverThumbnails()
    private let cache = NSCache<NSString, CGImage>()
    private let queue = DispatchQueue(label: "Stillleaf.covers", qos: .utility, attributes: .concurrent)

    init() { cache.countLimit = 300 }

    func cached(_ url: URL, maxPixels: Int) -> CGImage? {
        cache.object(forKey: key(url, maxPixels))
    }

    func load(_ url: URL, maxPixels: Int) async -> CGImage? {
        if let hit = cached(url, maxPixels: maxPixels) { return hit }
        return await withCheckedContinuation { continuation in
            queue.async { [cache] in
                let image = Self.thumbnail(url, maxPixels: maxPixels)
                if let image { cache.setObject(image, forKey: self.key(url, maxPixels)) }
                continuation.resume(returning: image)
            }
        }
    }

    /// Decodes at most `maxPixels` on the long edge, honouring EXIF orientation.
    static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func key(_ url: URL, _ maxPixels: Int) -> NSString { "\(maxPixels)|\(url.path)" as NSString }
}

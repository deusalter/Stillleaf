import AppKit
import ImageIO

/// Covers are immutable, content-addressed files. Decode once at display size,
/// off the UI thread, and let NSCache evict thumbnails under memory pressure.
@MainActor
final class CoverThumbnails {
    static let shared = CoverThumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: Task<NSImage?, Never>] = [:]

    private init() {
        cache.totalCostLimit = 12 * 1024 * 1024
        cache.countLimit = 64
    }

    func image(at path: String) async -> NSImage? {
        if let image = cache.object(forKey: path as NSString) { return image }
        if let task = pending[path] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            autoreleasepool {
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as [CFString: Any] as CFDictionary) else { return nil }
                return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            }
        }
        pending[path] = task
        let image = await task.value
        pending[path] = nil
        if let image {
            cache.setObject(image, forKey: path as NSString, cost: Int(image.size.width * image.size.height) * 4)
        }
        return image
    }
}

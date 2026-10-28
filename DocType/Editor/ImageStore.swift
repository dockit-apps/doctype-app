// Image sizes and thumbnails for the editor, loaded off the main thread.
//
// Sizes come from the file header only (ImageIO reads a few KB), so a note's
// images can be measured before it appears and it opens at its final layout.
// Thumbnails are decoded downsampled to the size they're shown at (×2 for
// Retina), never at full resolution, and kept in a cache with a memory limit,
// so a note full of 12-megapixel photos stays cheap.
// Layout fragments may draw off the main thread, so everything here is locked.

import AppKit
import ImageIO
import Synchronization

nonisolated final class ImageStore: Sendable {
    static let shared = ImageStore()
    /// Posted on the main thread (object: the file URL) when a thumbnail is decoded.
    static let thumbnailReady = Notification.Name("DocTypeImageThumbnailReady")

    struct Info: Sendable {
        /// Size in points: pixels adjusted for the image's DPI, so a Retina
        /// screenshot (144 dpi) shows at the size it was on screen.
        let size: CGSize
        let modified: Date?
    }

    private struct State {
        var infos: [URL: Info] = [:]
        /// Files that couldn't be read as images (missing, or not an image).
        var failed: Set<URL> = []
        var decoding: Set<URL> = []
    }

    private final class Thumbnail {
        let image: CGImage
        let maxPixelSize: Int
        init(image: CGImage, maxPixelSize: Int) {
            self.image = image
            self.maxPixelSize = maxPixelSize
        }
    }

    private let state = Mutex(State())
    /// NSCache is thread-safe; the limit is in bytes of decoded pixels.
    private nonisolated(unsafe) let thumbnails: NSCache<NSURL, Thumbnail> = {
        let cache = NSCache<NSURL, Thumbnail>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func info(for url: URL) -> Info? {
        state.withLock { $0.infos[url] }
    }

    func hasFailed(_ url: URL) -> Bool {
        state.withLock { $0.failed.contains(url) }
    }

    /// Reads the sizes of `urls` from their headers. With `refresh`, files read
    /// before are checked again (and a changed file's thumbnail is dropped), and
    /// files that failed are retried: used when a note opens.
    @concurrent
    func loadInfo(_ urls: some Collection<URL> & Sendable, refresh: Bool = false) async {
        for url in Set(urls) {
            let known = state.withLock { $0.infos[url] != nil || $0.failed.contains(url) }
            if known, !refresh { continue }
            let info = Self.readInfo(url)
            state.withLock { state in
                if let info {
                    if let old = state.infos[url], old.modified != info.modified { thumbnails.removeObject(forKey: url as NSURL) }
                    state.infos[url] = info
                    state.failed.remove(url)
                } else {
                    state.infos[url] = nil
                    state.failed.insert(url)
                }
            }
        }
    }

    /// The best thumbnail decoded so far (maybe smaller than asked). If it's
    /// missing or too small, a decode at `maxPixelSize` starts in the background
    /// and `thumbnailReady` is posted when it's done.
    func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        let cached = thumbnails.object(forKey: url as NSURL)
        if let cached, cached.maxPixelSize >= maxPixelSize { return cached.image }
        let shouldDecode = state.withLock { state in
            guard !state.decoding.contains(url), !state.failed.contains(url) else { return false }
            state.decoding.insert(url)
            return true
        }
        if shouldDecode {
            Task.detached(priority: .userInitiated) { [self] in
                let image = Self.decode(url, maxPixelSize: maxPixelSize)
                if let image {
                    thumbnails.setObject(Thumbnail(image: image, maxPixelSize: maxPixelSize), forKey: url as NSURL,
                                         cost: image.bytesPerRow * image.height)
                }
                state.withLock { state in
                    state.decoding.remove(url)
                    // Not decodable after all: stop asking (drawing would retry forever).
                    if image == nil { state.failed.insert(url) }
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.thumbnailReady, object: url)
                }
            }
        }
        return cached?.image
    }

    // MARK: - ImageIO

    private static func readInfo(_ url: URL) -> Info? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return nil }
        // EXIF orientations 5–8 are rotated by 90°.
        let rotated = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let dpi = (properties[kCGImagePropertyDPIWidth] as? CGFloat).flatMap { $0 >= 72 ? $0 : nil } ?? 72
        let scale = 72 / dpi
        let size = rotated ? CGSize(width: height * scale, height: width * scale) : CGSize(width: width * scale, height: height * scale)
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return Info(size: size, modified: modified)
    }

    private static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // applies EXIF rotation
            kCGImageSourceShouldCacheImmediately: true,  // decode now, not while drawing
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

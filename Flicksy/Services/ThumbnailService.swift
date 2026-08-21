//
//  ThumbnailService.swift
//  MediaBrowser
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Generates and caches downsampled image thumbnails.
///
/// Thumbnails are produced with ImageIO's `CGImageSourceCreateThumbnailAtIndex`,
/// which decodes only what is needed for the requested size — a full-resolution
/// decode never happens (spec sections 10 and 23). Generation runs on detached
/// background tasks; the actor only guards the cache and the in-flight table.
actor ThumbnailService {
    static let shared = ThumbnailService()

    /// A generated thumbnail plus the source image's true pixel dimensions
    /// (read from metadata, without a full decode).
    struct Thumbnail: @unchecked Sendable {
        let image: NSImage
        let pixelWidth: Int?
        let pixelHeight: Int?
    }

    /// Quantized maximum pixel sizes. Bucketing means nearby zoom levels reuse
    /// an existing cached thumbnail instead of regenerating every image for a
    /// slightly different pixel size.
    private enum SizeBucket: Int, CaseIterable {
        case small = 256
        case medium = 512
        case large = 1024
        /// Only requested by the full media viewer, which fills the window.
        case extraLarge = 2048

        static func bucket(forTargetPixels pixels: CGFloat) -> SizeBucket {
            switch pixels {
            case ..<384: return .small
            case ..<768: return .medium
            case ..<1536: return .large
            default: return .extraLarge
            }
        }
    }

    /// NSCache requires object values, so wrap the result struct in a class.
    private final class Box {
        let thumbnail: Thumbnail
        init(_ thumbnail: Thumbnail) { self.thumbnail = thumbnail }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        // Roughly 256 MB of decoded pixels; NSCache evicts under memory pressure.
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    /// Coalesces concurrent requests for the same url+size so a file is decoded
    /// only once even when several cells ask for it at the same moment.
    private var inFlight: [NSString: Task<Thumbnail?, Never>] = [:]

    /// Return a thumbnail whose largest edge is approximately `targetPixels`.
    /// Returns `nil` if the image cannot be decoded so the cell can show its
    /// "Preview unavailable" state.
    func thumbnail(for url: URL, targetPixels: CGFloat) async -> Thumbnail? {
        let bucket = SizeBucket.bucket(forTargetPixels: targetPixels)
        let key = "\(url.path)|\(bucket.rawValue)" as NSString

        if let cached = cache.object(forKey: key) {
            return cached.thumbnail
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let maxPixel = bucket.rawValue
        let task = Task.detached(priority: .utility) {
            Self.generate(url: url, maxPixel: maxPixel)
        }
        inFlight[key] = task

        let result = await task.value
        inFlight[key] = nil

        if let result {
            // Cost must reflect the downsampled thumbnail actually held in memory,
            // not the source file's dimensions, or a handful of large originals
            // would blow the limit and evict everything.
            let size = result.image.size
            cache.setObject(Box(result), forKey: key, cost: Int(size.width * size.height) * 4)
        }
        return result
    }

    // MARK: - Generation

    /// Synchronous ImageIO thumbnail generation, run off the actor via a detached
    /// task. `nonisolated` so it never touches actor-isolated state.
    nonisolated private static func generate(url: URL, maxPixel: Int) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let (pixelWidth, pixelHeight) = originalPixelSize(of: source)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            // Apply EXIF orientation so portrait photos are not rendered sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode into the cache immediately on this background thread rather
            // than lazily on the main thread at draw time.
            kCGImageSourceShouldCacheImmediately: true,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return Thumbnail(image: image, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    /// Read the source image's pixel dimensions from metadata without decoding it.
    nonisolated private static func originalPixelSize(of source: CGImageSource) -> (Int?, Int?) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        return (width, height)
    }
}

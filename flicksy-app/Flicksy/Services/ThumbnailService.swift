//
//  ThumbnailService.swift
//  MediaBrowser
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Bounds disk reads, image decoding, and cache writes so a fast scroll through a
/// huge folder cannot launch hundreds of competing operations. Cancelled waiters
/// consume and immediately return a permit when they reach the front of the queue.
private actor ThumbnailWorkLimiter {
    static let shared = ThumbnailWorkLimiter(limit: 6)

    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

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
        /// Fast first paint for the full media viewer.
        case extraLarge = 2048
        /// High-resolution viewer rendition so 100% zoom stays sharp on typical
        /// stills without decoding an unbounded original (spec section 17).
        case viewer = 8192

        static func bucket(forTargetPixels pixels: CGFloat) -> SizeBucket {
            switch pixels {
            case ..<384: return .small
            case ..<768: return .medium
            case ..<1536: return .large
            case ..<4096: return .extraLarge
            default: return .viewer
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
        let diskKey = PersistentMediaCache.key(for: url, variant: "image-thumbnail-\(bucket.rawValue)")
        let key = diskKey as NSString

        if let cached = cache.object(forKey: key) {
            return cached.thumbnail
        }

        if let existing = inFlight[key] {
            return await withTaskCancellationHandler {
                await existing.value
            } onCancel: {
                existing.cancel()
            }
        }

        let maxPixel = bucket.rawValue
        let task = Task<Thumbnail?, Never>.detached(priority: .userInitiated) {
            let limiter = ThumbnailWorkLimiter.shared
            await limiter.acquire()

            let result: Thumbnail?
            if Task.isCancelled {
                result = nil
            } else if let record = PersistentMediaCache.load(
                PersistentMediaCache.ImageRecord.self,
                namespace: "images",
                key: diskKey
            ), let image = PersistentMediaCache.decodedImage(from: record.imageData) {
                result = Thumbnail(
                    image: image,
                    pixelWidth: record.pixelWidth,
                    pixelHeight: record.pixelHeight
                )
            } else if let generated = Self.generate(url: url, maxPixel: maxPixel) {
                if !Task.isCancelled, let data = PersistentMediaCache.encodedImage(generated.image) {
                    PersistentMediaCache.store(
                        PersistentMediaCache.ImageRecord(
                            imageData: data,
                            pixelWidth: generated.pixelWidth,
                            pixelHeight: generated.pixelHeight
                        ),
                        namespace: "images",
                        key: diskKey
                    )
                }
                result = Task.isCancelled ? nil : generated
            } else {
                result = nil
            }

            await limiter.release()
            return result
        }
        inFlight[key] = task

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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

    /// Read an image's oriented pixel dimensions without decoding its pixels.
    /// Comparison uses this to choose its initial layout for off-screen items.
    nonisolated static func pixelSize(for url: URL) -> CGSize? {
        if let size = svgImage(at: url)?.size {
            guard size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0
            else { return nil }
            return size
        }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let (width, height) = originalPixelSize(of: source)
            if let width, let height, width > 0, height > 0 {
                return CGSize(width: width, height: height)
            }
        }
        return nil
    }

    // MARK: - Generation

    /// Synchronous ImageIO thumbnail generation, run off the actor via a detached
    /// task. `nonisolated` so it never touches actor-isolated state.
    nonisolated private static func generate(url: URL, maxPixel: Int) -> Thumbnail? {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .svg) == true {
            return generateSVG(url: url, maxPixel: maxPixel)
        }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
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

            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                return Thumbnail(image: image, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            }
        }

        return nil
    }

    /// ImageIO does not rasterize SVG files, even though AppKit can represent
    /// them. Draw AppKit's vector representation into an explicitly sized bitmap
    /// so SVGs use the same bounded memory, disk cache, and display paths as
    /// ordinary still images.
    nonisolated private static func generateSVG(url: URL, maxPixel: Int) -> Thumbnail? {
        guard let sourceImage = svgImage(at: url) else { return nil }

        let sourceSize = sourceImage.size
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0
        else { return nil }
        let largestEdge = max(sourceSize.width, sourceSize.height)

        let scale = CGFloat(maxPixel) / largestEdge
        let pixelWidth = max(1, Int((sourceSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((sourceSize.height * scale).rounded()))

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        bitmap.size = NSSize(width: pixelWidth, height: pixelHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        sourceImage.draw(
            in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = bitmap.cgImage else { return nil }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: pixelWidth, height: pixelHeight)
        )
        return Thumbnail(
            image: image,
            pixelWidth: reportedDimension(sourceSize.width),
            pixelHeight: reportedDimension(sourceSize.height)
        )
    }

    nonisolated private static func reportedDimension(_ value: CGFloat) -> Int? {
        guard value.isFinite, value > 0, value <= CGFloat(Int.max) else { return nil }
        return Int(value.rounded())
    }

    nonisolated private static func svgImage(at url: URL) -> NSImage? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .svg) == true else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    /// Read the source image's pixel dimensions from metadata without decoding it.
    nonisolated private static func originalPixelSize(of source: CGImageSource) -> (Int?, Int?) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return (nil, nil) }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }
}

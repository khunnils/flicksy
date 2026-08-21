//
//  VideoPreviewService.swift
//  MediaBrowser
//

import AVFoundation
import AppKit

/// Generates and caches representative poster frames for video files.
///
/// Poster frames come from `AVAssetImageGenerator`, which decodes a single frame
/// rather than instantiating a player — the grid can therefore show every video
/// without any playback resources existing (spec sections 11 and 23, rule 2).
/// Generation happens on detached background tasks; the actor only guards the
/// cache and the in-flight table.
actor VideoPreviewService {
    static let shared = VideoPreviewService()

    /// Quantized maximum pixel sizes, mirroring `ThumbnailService` so that
    /// nearby zoom levels reuse cached posters instead of regenerating every
    /// frame for a slightly different size.
    private enum SizeBucket: Int {
        case small = 256
        case medium = 512
        case large = 1024

        static func bucket(forTargetPixels pixels: CGFloat) -> SizeBucket {
            switch pixels {
            case ..<384: return .small
            case ..<768: return .medium
            default: return .large
            }
        }
    }

    /// NSCache requires object values.
    private final class Box {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        // Roughly 128 MB of decoded pixels; NSCache evicts under memory pressure.
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    private var inFlight: [NSString: Task<NSImage?, Never>] = [:]

    /// Return a poster frame whose largest edge is approximately `targetPixels`,
    /// or `nil` if no frame could be decoded so the cell can show its "Preview
    /// unavailable" state.
    func posterFrame(for url: URL, targetPixels: CGFloat) async -> NSImage? {
        let bucket = SizeBucket.bucket(forTargetPixels: targetPixels)
        let key = "\(url.path)|\(bucket.rawValue)" as NSString

        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let maxPixel = CGFloat(bucket.rawValue)
        let task = Task<NSImage?, Never>.detached(priority: .utility) {
            await Self.generate(url: url, maxPixel: maxPixel)
        }
        inFlight[key] = task

        let result = await task.value
        inFlight[key] = nil

        if let result {
            let size = result.size
            cache.setObject(Box(result), forKey: key, cost: Int(size.width * size.height) * 4)
        }
        return result
    }

    // MARK: - Generation

    nonisolated private static func generate(url: URL, maxPixel: CGFloat) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)

        // Rotate portrait footage upright rather than emitting a sideways frame.
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)

        // A generous tolerance lets the generator settle on the nearest keyframe
        // instead of decoding forward to an exact time, which is dramatically
        // faster and is visually irrelevant for a poster frame.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let time = await posterTime(for: asset)

        guard let cgImage = try? await generator.image(at: time).image else {
            // Opening frames are often black or missing on some encodes; fall back
            // to the very start before giving up entirely.
            guard time != .zero,
                  let fallback = try? await generator.image(at: .zero).image
            else { return nil }
            return NSImage(cgImage: fallback, size: NSSize(width: fallback.width, height: fallback.height))
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Pick a frame a little way into the clip. The first frames of a clip are
    /// frequently a fade-in or slate, so 10% in (capped at three seconds, to stay
    /// near the start of long files) is more representative than time zero.
    nonisolated private static func posterTime(for asset: AVURLAsset) async -> CMTime {
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else {
            return .zero
        }
        let seconds = min(duration.seconds * 0.1, 3.0)
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

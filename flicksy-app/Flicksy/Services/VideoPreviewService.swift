//
//  VideoPreviewService.swift
//  MediaBrowser
//

import AVFoundation
import AppKit

/// Generates and caches representative poster frames and hover-scrub storyboards
/// for video files.
///
/// Poster frames come from `AVAssetImageGenerator`, which decodes a single frame
/// rather than instantiating a player — the grid can therefore show every video
/// without any playback resources existing (spec sections 11 and 23, rule 2).
/// Storyboards are a short strip of the same kind of frame, produced lazily on
/// first hover rather than during folder scanning (spec section 13).
/// Generation happens on detached background tasks; the actor only guards the
/// caches and the in-flight tables.
actor VideoPreviewService {
    static let shared = VideoPreviewService()

    /// A cached strip of representative frames used for hover scrubbing.
    struct Storyboard: @unchecked Sendable {
        let frames: [NSImage]
        let duration: TimeInterval
    }

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

    private final class StoryboardBox {
        let storyboard: Storyboard
        init(_ storyboard: Storyboard) { self.storyboard = storyboard }
    }

    private let storyboardCache: NSCache<NSString, StoryboardBox> = {
        let cache = NSCache<NSString, StoryboardBox>()
        // Storyboards are a handful of small frames each; this holds dozens of clips.
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    private var storyboardInFlight: [NSString: Task<Storyboard?, Never>] = [:]
    /// Paths whose storyboard generation already failed, so a hover does not
    /// keep re-decoding a broken file.
    private var storyboardFailures: Set<NSString> = []

    /// Return a poster frame whose largest edge is approximately `targetPixels`,
    /// or `nil` if no frame could be decoded so the cell can show its "Preview
    /// unavailable" state.
    func posterFrame(for url: URL, targetPixels: CGFloat) async -> NSImage? {
        let bucket = SizeBucket.bucket(forTargetPixels: targetPixels)
        let diskKey = PersistentMediaCache.key(for: url, variant: "video-poster-\(bucket.rawValue)")
        let key = diskKey as NSString

        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        if let existing = inFlight[key] {
            return await withTaskCancellationHandler {
                await existing.value
            } onCancel: {
                existing.cancel()
            }
        }

        let maxPixel = CGFloat(bucket.rawValue)
        let task = Task<NSImage?, Never>.detached(priority: .utility) {
            if let record = PersistentMediaCache.load(
                PersistentMediaCache.ImageRecord.self,
                namespace: "video-posters",
                key: diskKey
            ), let image = PersistentMediaCache.decodedImage(from: record.imageData) {
                return image
            }

            guard !Task.isCancelled,
                  let image = await Self.generate(url: url, maxPixel: maxPixel)
            else { return nil }

            if !Task.isCancelled, let data = PersistentMediaCache.encodedImage(image) {
                PersistentMediaCache.store(
                    PersistentMediaCache.ImageRecord(
                        imageData: data,
                        pixelWidth: nil,
                        pixelHeight: nil
                    ),
                    namespace: "video-posters",
                    key: diskKey
                )
            }
            return image
        }
        inFlight[key] = task

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inFlight[key] = nil

        if let result {
            let size = result.size
            cache.setObject(Box(result), forKey: key, cost: Int(size.width * size.height) * 4)
        }
        return result
    }

    /// Return a lazily generated storyboard for hover scrubbing, or `nil` if
    /// frames could not be decoded. Approximately 10–20 frames, produced only
    /// when a cell first asks — never during the folder scan (spec section 13).
    func storyboard(for url: URL, targetPixels: CGFloat) async -> Storyboard? {
        let bucket = SizeBucket.bucket(forTargetPixels: targetPixels)
        let diskKey = PersistentMediaCache.key(for: url, variant: "video-storyboard-\(bucket.rawValue)")
        let key = diskKey as NSString

        if let cached = storyboardCache.object(forKey: key) {
            return cached.storyboard
        }
        if storyboardFailures.contains(key) {
            return nil
        }
        if let existing = storyboardInFlight[key] {
            return await withTaskCancellationHandler {
                await existing.value
            } onCancel: {
                existing.cancel()
            }
        }

        let maxPixel = CGFloat(bucket.rawValue)
        let task = Task<Storyboard?, Never>.detached(priority: .utility) {
            if let record = PersistentMediaCache.load(
                PersistentMediaCache.StoryboardRecord.self,
                namespace: "video-storyboards",
                key: diskKey
            ) {
                let frames = record.frames.compactMap(PersistentMediaCache.decodedImage(from:))
                if frames.count == record.frames.count, !frames.isEmpty {
                    return Storyboard(frames: frames, duration: record.duration)
                }
            }

            guard !Task.isCancelled,
                  let storyboard = await Self.generateStoryboard(url: url, maxPixel: maxPixel)
            else { return nil }

            if !Task.isCancelled {
                let frames = storyboard.frames.compactMap(PersistentMediaCache.encodedImage(_:))
                if frames.count == storyboard.frames.count {
                    PersistentMediaCache.store(
                        PersistentMediaCache.StoryboardRecord(
                            frames: frames,
                            duration: storyboard.duration
                        ),
                        namespace: "video-storyboards",
                        key: diskKey
                    )
                }
            }
            return storyboard
        }
        storyboardInFlight[key] = task

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        storyboardInFlight[key] = nil

        if let result {
            let cost = result.frames.reduce(0) { partial, image in
                partial + Int(image.size.width * image.size.height) * 4
            }
            storyboardCache.setObject(StoryboardBox(result), forKey: key, cost: cost)
        } else if !Task.isCancelled {
            storyboardFailures.insert(key)
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

    /// Decode a short strip of frames spread across the clip. Mouse-X mapping
    /// then picks the nearest cached frame instead of seeking a live player
    /// (spec section 13).
    nonisolated private static func generateStoryboard(url: URL, maxPixel: CGFloat) async -> Storyboard? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.isNumeric,
              duration.seconds > 0
        else { return nil }

        let count = frameCount(for: duration.seconds)
        let times: [CMTime] = (0..<count).map { index in
            let seconds = duration.seconds * (Double(index) + 0.5) / Double(count)
            return CMTime(seconds: seconds, preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)

        // Tight enough that neighbouring hover frames actually differ, loose
        // enough that the generator can still snap to a nearby keyframe.
        let slice = duration.seconds / Double(count)
        let tolerance = min(0.2, slice / 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: tolerance, preferredTimescale: 600)

        var collected: [(CMTime, NSImage)] = []
        collected.reserveCapacity(count)

        for await result in generator.images(for: times) {
            if Task.isCancelled {
                generator.cancelAllCGImageGeneration()
                return nil
            }
            guard let cgImage = try? result.image else { continue }
            collected.append((
                result.requestedTime,
                NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            ))
        }

        guard !collected.isEmpty else { return nil }
        collected.sort { CMTimeCompare($0.0, $1.0) < 0 }
        return Storyboard(frames: collected.map(\.1), duration: duration.seconds)
    }

    /// Short clips need fewer samples; long ones cap at 20 so a hover does not
    /// decode a contact sheet's worth of frames (spec section 13).
    nonisolated private static func frameCount(for duration: TimeInterval) -> Int {
        switch duration {
        case ..<2: return 8
        case ..<10: return 12
        case ..<30: return 16
        default: return 20
        }
    }
}

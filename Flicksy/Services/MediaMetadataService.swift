//
//  MediaMetadataService.swift
//  MediaBrowser
//

import AVFoundation

/// Reads duration and pixel dimensions from time-based media.
///
/// Everything here goes through `AVAsset`'s async `load(_:)` API, which performs
/// the demux/parse work off the calling thread. Nothing is ever loaded
/// synchronously, so a cell can ask for metadata without stalling the grid
/// (spec section 23, rule 9).
actor MediaMetadataService {
    static let shared = MediaMetadataService()

    struct Metadata: Sendable {
        /// `nil` for assets that report an indefinite or unavailable duration.
        var duration: TimeInterval?
        var width: Int?
        var height: Int?
    }

    private var cache: [String: Metadata] = [:]

    /// Coalesces concurrent requests for the same file so an asset is parsed once
    /// even when the cell and the viewer ask at the same moment.
    private var inFlight: [String: Task<Metadata, Never>] = [:]

    /// Load duration and dimensions for a video (or audio) file.
    ///
    /// Never throws: an unreadable or corrupt file yields a `Metadata` with `nil`
    /// fields so the caller simply omits the detail rather than failing the row
    /// (spec section 24).
    func metadata(for url: URL) async -> Metadata {
        let key = url.path

        if let cached = cache[key] { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<Metadata, Never>.detached(priority: .utility) {
            await Self.load(url: url)
        }
        inFlight[key] = task

        let result = await task.value
        inFlight[key] = nil
        cache[key] = result
        return result
    }

    // MARK: - Loading

    nonisolated private static func load(url: URL) async -> Metadata {
        let asset = AVURLAsset(url: url)

        var metadata = Metadata()

        if let duration = try? await asset.load(.duration), duration.isNumeric {
            metadata.duration = duration.seconds
        }

        // Dimensions come from the video track's natural size corrected by its
        // preferred transform, otherwise footage shot in portrait reports
        // landscape dimensions.
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let displaySize = naturalSize.applying(transform)
            metadata.width = Int(abs(displaySize.width).rounded())
            metadata.height = Int(abs(displaySize.height).rounded())
        }

        return metadata
    }
}

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
        /// Average encoded bits per second, when the container reports it.
        var bitRate: Int?
        var sampleRate: Double?
        var channelCount: Int?
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

        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            if let dataRate = try? await track.load(.estimatedDataRate), dataRate > 0 {
                metadata.bitRate = Int(dataRate.rounded())
            }

            if let descriptions = try? await track.load(.formatDescriptions),
               let format = descriptions.first,
               let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                if basic.mSampleRate > 0 {
                    metadata.sampleRate = basic.mSampleRate
                }
                if basic.mChannelsPerFrame > 0 {
                    metadata.channelCount = Int(basic.mChannelsPerFrame)
                }

                // Uncompressed tracks often omit estimatedDataRate. Derive their
                // bit rate from the stream layout when enough information exists.
                if metadata.bitRate == nil,
                   basic.mSampleRate > 0,
                   basic.mChannelsPerFrame > 0,
                   basic.mBitsPerChannel > 0 {
                    metadata.bitRate = Int(
                        basic.mSampleRate
                            * Double(basic.mChannelsPerFrame)
                            * Double(basic.mBitsPerChannel)
                    )
                }
            }
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

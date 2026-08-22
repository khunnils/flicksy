//
//  WaveformService.swift
//  MediaBrowser
//

import AVFoundation

/// Generates and caches normalized waveform peaks for audio files.
///
/// Samples are streamed through `AVAssetReader` and folded into peaks as each
/// buffer arrives, so decoding a long file never holds more than one buffer of
/// PCM in memory (spec section 23, rule 8). Generation runs on detached
/// background tasks; the actor only guards the cache and the in-flight table.
actor WaveformService {
    static let shared = WaveformService()

    /// Peaks produced per file. A few hundred values is ample for a waveform a
    /// few hundred points wide (spec section 14); `WaveformView` reduces further
    /// to match the number of bars it can actually draw.
    static let resolution = 480

    /// Peaks are tiny (a few kilobytes per file), so unlike the thumbnail caches
    /// this one needs no eviction policy. `nil` records a file that could not be
    /// decoded, which keeps a broken file from being retried on every scroll.
    private var cache: [String: [Float]?] = [:]

    /// Coalesces concurrent requests for the same file so it is decoded once.
    private var inFlight: [String: Task<[Float]?, Never>] = [:]

    /// Normalized (0...1) peak amplitudes for `url`, or `nil` if the audio could
    /// not be decoded — the row then shows an unavailable state while the rest of
    /// the folder keeps browsing normally (spec section 24).
    func waveform(for url: URL) async -> [Float]? {
        let key = PersistentMediaCache.key(for: url, variant: "waveform-\(Self.resolution)")

        if let cached = cache[key] { return cached }
        if let existing = inFlight[key] {
            return await withTaskCancellationHandler {
                await existing.value
            } onCancel: {
                existing.cancel()
            }
        }

        let task = Task<[Float]?, Never>.detached(priority: .utility) {
            if let record = PersistentMediaCache.load(
                PersistentMediaCache.WaveformRecord.self,
                namespace: "waveforms",
                key: key
            ) {
                return record.peaks
            }

            guard !Task.isCancelled,
                  let peaks = await Self.generate(url: url, resolution: Self.resolution)
            else { return nil }

            if !Task.isCancelled {
                PersistentMediaCache.store(
                    PersistentMediaCache.WaveformRecord(peaks: peaks),
                    namespace: "waveforms",
                    key: key
                )
            }
            return peaks
        }
        inFlight[key] = task

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inFlight[key] = nil
        if !Task.isCancelled {
            cache[key] = result
        }
        return result
    }

    // MARK: - Generation

    /// Decode `url` and reduce it to at most `resolution` normalized peaks.
    /// `nonisolated` so it never touches actor-isolated state.
    nonisolated private static func generate(url: URL, resolution: Int) async -> [Float]? {
        let asset = AVURLAsset(url: url)

        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration),
              duration.isNumeric, duration.seconds > 0,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }

        // 16-bit signed integer PCM keeps both the decode and the per-sample
        // arithmetic cheap. Leaving the sample rate and channel count unset means
        // the reader hands back the file's native layout with no resampling.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let layout = await audioLayout(of: track)

        // Samples are interleaved, so taking the peak across a run of interleaved
        // values is the same as taking the peak across every channel of the frames
        // in that run — no per-channel bookkeeping is needed.
        let estimatedSamples = duration.seconds * layout.sampleRate * Double(layout.channels)
        let samplesPerBucket = max(1, Int((estimatedSamples / Double(resolution)).rounded()))

        var peaks: [Float] = []
        peaks.reserveCapacity(resolution)

        // Accumulated in Int32 because `abs(Int16.min)` overflows Int16.
        var bucketPeak: Int32 = 0
        var samplesInBucket = 0
        var scratch: [Int16] = []

        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }

            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = byteCount / MemoryLayout<Int16>.size
            guard sampleCount > 0 else { continue }

            // One scratch buffer is grown as needed and reused across buffers
            // rather than allocating per buffer.
            if scratch.count < sampleCount {
                scratch = [Int16](repeating: 0, count: sampleCount)
            }

            let copied = scratch.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: raw.baseAddress!
                ) == noErr
            }
            guard copied else { continue }

            for index in 0..<sampleCount {
                let sample = Int32(scratch[index])
                let magnitude = sample < 0 ? -sample : sample
                if magnitude > bucketPeak { bucketPeak = magnitude }

                samplesInBucket += 1
                if samplesInBucket == samplesPerBucket {
                    peaks.append(Float(bucketPeak))
                    bucketPeak = 0
                    samplesInBucket = 0
                }
            }
        }

        // A failure partway through would yield a waveform whose width no longer
        // corresponds to the clip's duration, which would make click-to-seek lie.
        guard reader.status != .failed else { return nil }

        if samplesInBucket > 0 {
            peaks.append(Float(bucketPeak))
        }
        guard !peaks.isEmpty else { return nil }

        return normalized(reduce(peaks, to: resolution))
    }

    /// Sample rate and channel count, read from the track's format description.
    /// The fallbacks only matter for files that describe themselves oddly; a
    /// slightly wrong estimate just shifts bucket sizes, and `reduce(_:to:)`
    /// absorbs the difference.
    nonisolated private static func audioLayout(of track: AVAssetTrack) async -> (sampleRate: Double, channels: Int) {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let format = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return (44_100, 1) }

        return (
            basic.mSampleRate > 0 ? basic.mSampleRate : 44_100,
            basic.mChannelsPerFrame > 0 ? Int(basic.mChannelsPerFrame) : 1
        )
    }

    /// Max-pool `peaks` down to `limit` values. Peak counts overshoot whenever the
    /// duration/sample-rate estimate ran low, and merging preserves transients
    /// where averaging would smear them away.
    nonisolated private static func reduce(_ peaks: [Float], to limit: Int) -> [Float] {
        guard peaks.count > limit, limit > 0 else { return peaks }

        return (0..<limit).map { index in
            let start = index * peaks.count / limit
            let end = max(start + 1, (index + 1) * peaks.count / limit)
            return peaks[start..<end].max() ?? 0
        }
    }

    /// Scale so the file's loudest point reaches full height. Normalizing per file
    /// rather than against Int16's range keeps quiet recordings readable, which is
    /// what matters when the waveform is used to find a moment in a clip.
    nonisolated private static func normalized(_ peaks: [Float]) -> [Float] {
        guard let loudest = peaks.max(), loudest > 0 else {
            // Digital silence: a flat line is the honest representation.
            return Array(repeating: 0, count: peaks.count)
        }
        return peaks.map { $0 / loudest }
    }
}

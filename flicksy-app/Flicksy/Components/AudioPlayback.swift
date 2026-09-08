//
//  AudioPlayback.swift
//  MediaBrowser
//

import AVFoundation
import Observation
import MediaToolbox

/// Owns a single audio `AVPlayer` and publishes just enough state to draw a
/// playhead (spec section 15).
///
/// Audio needs no `AVPlayerView`: the waveform *is* the transport, so this type
/// exposes observable position state instead of wrapping an AppKit player view.
/// As with `VideoPlayback`, SwiftUI gives no guarantee about when a `@State`
/// object is released, so the owner must call `tearDown()` explicitly rather than
/// relying on `deinit`.
@Observable
@MainActor
final class AudioPlayback {
    private(set) var isPlaying = false { didSet { onPlayingChange?(isPlaying) } }
    var onPlayingChange: ((Bool) -> Void)?
    private(set) var meter: AudioLevelMeter?
    private var setupTask: Task<Void, Never>?
    private var setupComplete = true
    private var seekInFlight = false
    private var nextSeek: TimeInterval?
    private var seekGeneration = 0
    private(set) var currentTime: TimeInterval = 0

    /// `nil` until the asset reports a usable duration.
    private(set) var duration: TimeInterval?

    /// Inclusive in/out times. `nil` plays the whole file.
    var playbackRange: ClosedRange<TimeInterval>? {
        didSet { applyPlaybackBounds() }
    }

    /// When true, reaching the range end seeks back to the start and continues.
    var isLooping = false

    /// Played fraction of the clip, 0...1.
    var progress: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private let player: AVPlayer
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var durationTask: Task<Void, Never>?

    /// A seek requested before the duration was known, applied once it arrives.
    private var pendingSeekFraction: Double?

    /// `duration` should be passed in when the row already has it, which avoids a
    /// visible delay before the playhead can be positioned.
    init(url: URL, duration: TimeInterval?, meteringEnabled: Bool = false) {
        player = AVPlayer(url: url)
        self.duration = duration
        if meteringEnabled { meter = AudioLevelMeter(); setupComplete = false }

        // Hold at the end rather than stopping abruptly; `handlePlaybackEnded`
        // either loops or rewinds so the play button becomes Replay.
        player.actionAtItemEnd = .pause

        // 20 Hz is smooth for a playhead a few hundred points wide while leaving
        // the main actor essentially idle during playback.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // Registered on the main queue, so this always runs on the main actor
            // even though the API's closure is not typed as isolated.
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                if !self.seekInFlight { self.currentTime = time.seconds }
                if self.isPlaying && !self.seekInFlight { self.meter?.update(at: time.seconds) }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePlaybackEnded()
            }
        }

        applyPlaybackBounds()
        if let meter {
            setupTask = Task { [weak self] in
                defer {
                    if !Task.isCancelled, let self {
                        self.setupComplete = true
                        if self.isPlaying { self.player.play() }
                    }
                }
                let asset = AVURLAsset(url: url)
                guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
                      tracks.count == 1, let track = tracks.first,
                      let descriptions = try? await track.load(.formatDescriptions),
                      let description = descriptions.first,
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      !Task.isCancelled, let self else {
                    if !Task.isCancelled { meter.markUnavailable() }
                    return
                }
                guard let tap = meter.makeTap(sourceChannels: Int(format.mChannelsPerFrame)) else { return }
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.audioTapProcessor = tap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [parameters]
                self.player.currentItem?.audioMix = mix
            }
        }

        if duration == nil {
            // Goes through the shared metadata cache, so the parse is usually
            // already done by the time the row asks for playback.
            durationTask = Task { [weak self] in
                let metadata = await MediaMetadataService.shared.metadata(for: url)
                guard let self, let resolved = metadata.duration else { return }
                self.duration = resolved
                self.applyPendingSeek()
                self.applyPlaybackBounds()
            }
        }
    }

    // MARK: - Transport

    func play() {
        if let range = effectiveRange {
            let epsilon = 0.02
            if currentTime < range.lowerBound - epsilon || currentTime >= range.upperBound - epsilon {
                seek(toTime: range.lowerBound)
            }
        }
        isPlaying = true
        if setupComplete { player.play() }
    }

    func pause() {
        player.pause()
        isPlaying = false
        // Keep already-decoded future samples for resume; seeking invalidates them.
        meter?.reset(discardPending: false)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    static let skipInterval: TimeInterval = 5

    /// Seek to a 0...1 position within the clip, clamped to `playbackRange`.
    func seek(toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)

        guard let duration, duration > 0 else {
            pendingSeekFraction = clamped
            return
        }

        var time = clamped * duration
        if let range = effectiveRange {
            time = min(max(time, range.lowerBound), range.upperBound)
        }
        seek(toTime: time)
    }

    /// Skip forward or backward by `seconds`, staying inside the play range.
    func skip(by seconds: TimeInterval) {
        let bounds = effectiveRange ?? (0...(duration ?? 0))
        seek(toTime: min(max(currentTime + seconds, bounds.lowerBound), bounds.upperBound))
    }

    /// Stop playback and release the decode pipeline.
    func tearDown() {
        setupTask?.cancel()
        setupTask = nil
        seekGeneration += 1
        nextSeek = nil
        durationTask?.cancel()
        durationTask = nil

        player.pause()
        isPlaying = false
        meter?.reset()

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Private

    private var effectiveRange: ClosedRange<TimeInterval>? {
        guard let playbackRange else { return nil }
        guard let duration, duration > 0 else { return playbackRange }
        let start = min(max(playbackRange.lowerBound, 0), duration)
        let end = min(max(playbackRange.upperBound, start), duration)
        return start...end
    }

    private func seek(toTime time: TimeInterval) {
        guard time.isFinite else { return }
        currentTime = time
        meter?.reset()
        if seekInFlight { nextSeek = time; return }
        seekInFlight = true
        let generation = seekGeneration
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.seekInFlight = false
                self.meter?.reset()
                if let next = self.nextSeek {
                    self.nextSeek = nil
                    self.seek(toTime: next)
                }
            }
        }
    }

    private func applyPlaybackBounds() {
        guard let item = player.currentItem else { return }
        if let range = effectiveRange {
            item.forwardPlaybackEndTime = CMTime(seconds: range.upperBound, preferredTimescale: 600)
            if currentTime < range.lowerBound || currentTime > range.upperBound {
                seek(toTime: range.lowerBound)
            }
        } else {
            item.forwardPlaybackEndTime = .invalid
        }
    }

    private func handlePlaybackEnded() {
        meter?.reset()
        let start = effectiveRange?.lowerBound ?? 0
        if isLooping {
            seek(toTime: start)
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
            currentTime = start
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        }
    }

    private func applyPendingSeek() {
        guard let pendingSeekFraction else { return }
        self.pendingSeekFraction = nil
        seek(toFraction: pendingSeekFraction)
    }
}

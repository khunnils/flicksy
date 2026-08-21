//
//  AudioPlayback.swift
//  MediaBrowser
//

import AVFoundation
import Observation

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
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0

    /// `nil` until the asset reports a usable duration.
    private(set) var duration: TimeInterval?

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
    init(url: URL, duration: TimeInterval?) {
        player = AVPlayer(url: url)
        self.duration = duration

        // Hold at the end rather than stopping abruptly; `handlePlaybackEnded`
        // rewinds so the play button becomes Replay.
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
                self?.currentTime = time.seconds
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

        if duration == nil {
            // Goes through the shared metadata cache, so the parse is usually
            // already done by the time the row asks for playback.
            durationTask = Task { [weak self] in
                let metadata = await MediaMetadataService.shared.metadata(for: url)
                guard let self, let resolved = metadata.duration else { return }
                self.duration = resolved
                self.applyPendingSeek()
            }
        }
    }

    // MARK: - Transport

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seek to a 0...1 position within the clip.
    func seek(toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)

        guard let duration, duration > 0 else {
            pendingSeekFraction = clamped
            return
        }

        let time = clamped * duration
        // Move the playhead now rather than waiting for the seek to complete, so
        // clicking the waveform feels immediate.
        currentTime = time
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Stop playback and release the decode pipeline.
    func tearDown() {
        durationTask?.cancel()
        durationTask = nil

        player.pause()
        isPlaying = false

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

    private func handlePlaybackEnded() {
        isPlaying = false
        currentTime = 0
        player.seek(to: .zero)
    }

    private func applyPendingSeek() {
        guard let pendingSeekFraction else { return }
        self.pendingSeekFraction = nil
        seek(toFraction: pendingSeekFraction)
    }
}

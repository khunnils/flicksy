//
//  VideoPlayerView.swift
//  MediaBrowser
//

import AVKit
import SwiftUI

/// Owns a single `AVPlayer` and, crucially, its teardown.
///
/// An `AVPlayer` holds decode buffers and a render pipeline, so the browser keeps
/// as few of them alive as possible (spec section 12). SwiftUI gives no guarantee
/// about when a `@State` object is deallocated, so every owner must call
/// `tearDown()` explicitly when the player is no longer needed rather than relying
/// on `deinit`.
@MainActor
final class VideoPlayback {
    let player: AVPlayer

    private var endObserver: NSObjectProtocol?

    init(url: URL) {
        player = AVPlayer(url: url)

        // Hold the final frame rather than blanking to black when the clip ends.
        player.actionAtItemEnd = .pause

        // Rewinding at the end turns the transport's play button into Replay
        // (spec section 12) without needing a separate control.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
        }
    }

    func play() {
        player.play()
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// Stop playback and release the decode pipeline.
    func tearDown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }
}

/// SwiftUI wrapper around `AVPlayerView`.
///
/// `AVPlayerView` is used in preference to a hand-built transport so playback
/// gets the standard macOS scrubber, volume, and keyboard behaviour for free
/// (spec section 18).
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var controlsStyle: AVPlayerViewControlsStyle = .inline
    var showsFullScreenToggleButton = false

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controlsStyle
        view.showsFullScreenToggleButton = showsFullScreenToggleButton
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false

        // This is a media browser, not a media player: auditioning clips should
        // not take over the system's Now Playing controls.
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        nsView.controlsStyle = controlsStyle
        nsView.showsFullScreenToggleButton = showsFullScreenToggleButton
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        // Detach so the view does not keep the player's render pipeline alive
        // after SwiftUI removes it from the hierarchy.
        nsView.player = nil
    }
}

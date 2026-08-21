//
//  MediaViewer.swift
//  MediaBrowser
//

import AVKit
import SwiftUI

/// The focused full-window media viewer (spec section 16).
///
/// Presented as an overlay on the whole window rather than a sheet so it covers
/// the sidebar too. Shortcuts are attached to real `Button`s rather than
/// `onKeyPress` because key equivalents are dispatched by the window, so they
/// keep working while focus sits inside the embedded `AVPlayerView`.
struct MediaViewer: View {
    let item: MediaItem

    @Environment(BrowserModel.self) private var model

    /// Non-nil only while a video is being viewed. Owned here rather than in a
    /// child view so the Space shortcut can drive it.
    @State private var playback: VideoPlayback?

    var body: some View {
        ZStack {
            Color.black
                .opacity(0.97)
                .ignoresSafeArea()

            media
                .padding(.horizontal, 24)
                .padding(.top, 44)
                .padding(.bottom, 72)

            chrome
            shortcuts
        }
        .task(id: item.id) {
            preparePlayback()
        }
        .onDisappear {
            teardownPlayback()
        }
    }

    @ViewBuilder
    private var media: some View {
        switch item.type {
        case .image:
            ViewerImage(item: item)
        case .video:
            if let playback {
                VideoPlayerView(
                    player: playback.player,
                    controlsStyle: .floating,
                    showsFullScreenToggleButton: true
                )
            } else {
                Color.clear
            }
        case .audio:
            // Audio is never opened here; it lives in its own waveform section.
            EmptyView()
        }
    }

    // MARK: - Playback

    /// Build a player for the current item, discarding any player left over from
    /// the previously viewed clip so only one exists at a time.
    private func preparePlayback() {
        teardownPlayback()
        guard item.type == .video else { return }

        let controller = VideoPlayback(url: item.url)
        playback = controller
        controller.play()
    }

    private func teardownPlayback() {
        playback?.tearDown()
        playback = nil
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    model.closeViewer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.85), .black.opacity(0.4))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close viewer (Esc)")
            }
            .padding(16)

            Spacer()

            HStack(spacing: 20) {
                navigationButton(
                    systemImage: "chevron.left",
                    shortcut: .leftArrow,
                    enabled: model.canShowPreviousInViewer,
                    help: "Previous (←)"
                ) {
                    model.showPreviousInViewer()
                }

                Text(item.name)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)

                navigationButton(
                    systemImage: "chevron.right",
                    shortcut: .rightArrow,
                    enabled: model.canShowNextInViewer,
                    help: "Next (→)"
                ) {
                    model.showNextInViewer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(.bottom, 16)
        }
    }

    private func navigationButton(
        systemImage: String,
        shortcut: KeyEquivalent,
        enabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(enabled ? .white : Color.white.opacity(0.25))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(shortcut, modifiers: [])
        .help(help)
    }

    /// Shortcuts with no on-screen control of their own. Zero-sized and hidden
    /// from accessibility, they exist purely to register key equivalents.
    private var shortcuts: some View {
        ZStack {
            Button("Play/Pause") {
                playback?.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(playback == nil)

            Button("Toggle Full Screen") {
                NSApplication.shared.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut(KeyEquivalent("f"), modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Image

/// Fit-to-window image display.
///
/// Loads a larger rendition than the grid uses, but still through ImageIO's
/// downsampling path rather than a full-resolution decode (spec section 23,
/// rule 1). Zoom and pan arrive in Milestone 4.
private struct ViewerImage: View {
    let item: MediaItem

    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if didFail {
                PreviewUnavailable()
            } else {
                ProgressView()
            }
        }
        .task(id: item.url.path) {
            didFail = false
            let result = await ThumbnailService.shared.thumbnail(for: item.url, targetPixels: 2048)
            guard !Task.isCancelled else { return }
            if let result {
                image = result.image
            } else {
                didFail = true
            }
        }
    }
}

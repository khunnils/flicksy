//
//  VideoCell.swift
//  MediaBrowser
//

import AVKit
import SwiftUI

/// A grid cell for a video: a poster frame that can be swapped for a live
/// `AVPlayer` on demand.
///
/// No playback resources exist until the user presses play (spec sections 11 and
/// 12). The cell then claims `BrowserModel.playingVideoID`; because that is a
/// single value, claiming it implicitly evicts whichever cell was playing before,
/// so at most one `AVPlayer` is ever alive in the grid.
struct VideoCell: View {
    let item: MediaItem
    let targetPixels: CGFloat

    @Environment(BrowserModel.self) private var model

    @State private var poster: NSImage?
    @State private var metadata: MediaMetadataService.Metadata?
    @State private var didFail = false
    @State private var playback: VideoPlayback?

    private var isActive: Bool { model.playingVideoID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaCardBackground {
                content
            }
            .aspectRatio(1, contentMode: .fit)

            MediaCaption(title: item.name, subtitle: subtitle)
        }
        .task(id: posterTaskID) {
            await loadPoster()
        }
        .task(id: item.url.path) {
            await loadMetadata()
        }
        .onChange(of: isActive) { _, nowActive in
            if nowActive {
                startPlayback()
            } else {
                stopPlayback()
            }
        }
        .onDisappear {
            // Scrolling a playing cell out of the grid must not leave it playing
            // in the background (spec section 12).
            stopPlayback()
            if isActive {
                model.playingVideoID = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let playback {
            VideoPlayerView(player: playback.player, controlsStyle: .inline)
        } else if let poster {
            posterView(poster)
        } else if didFail {
            PreviewUnavailable()
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func posterView(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.medium)
            .scaledToFit()
            .padding(2)
            .overlay {
                Button {
                    model.playingVideoID = item.id
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .shadow(radius: 4)
                }
                .buttonStyle(.plain)
                .help("Play inline")
            }
            // Clicking the frame itself (rather than the play button) opens the
            // focused viewer, per spec section 16.
            .contentShape(Rectangle())
            .onTapGesture {
                model.openViewer(item)
            }
    }

    private var subtitle: String? {
        MediaFormatting.detailLine([
            MediaFormatting.duration(metadata?.duration),
            MediaFormatting.dimensions(width: metadata?.width, height: metadata?.height),
        ]) ?? MediaFormatting.fileSize(item.fileSize)
    }

    /// Re-run poster generation when either the file or the size bucket changes.
    private var posterTaskID: String {
        "\(item.url.path)|\(Int(targetPixels))"
    }

    // MARK: - Loading

    private func loadPoster() async {
        didFail = false
        let image = await VideoPreviewService.shared.posterFrame(for: item.url, targetPixels: targetPixels)
        guard !Task.isCancelled else { return }
        if let image {
            poster = image
        } else {
            didFail = true
        }
    }

    private func loadMetadata() async {
        let result = await MediaMetadataService.shared.metadata(for: item.url)
        guard !Task.isCancelled else { return }
        metadata = result
    }

    // MARK: - Playback

    private func startPlayback() {
        guard playback == nil else { return }
        let controller = VideoPlayback(url: item.url)
        playback = controller
        controller.play()
    }

    private func stopPlayback() {
        playback?.tearDown()
        playback = nil
    }
}

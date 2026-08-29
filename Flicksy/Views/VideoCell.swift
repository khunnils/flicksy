//
//  VideoCell.swift
//  MediaBrowser
//

import AVKit
import SwiftUI

/// A grid cell for a video: a poster frame that can be swapped for a live
/// `AVPlayer` on demand, or scrubbed by hovering (spec sections 11–13).
///
/// No playback resources exist until the user presses play. The cell then claims
/// `BrowserModel.playingVideoID`; because that is a single value, claiming it
/// implicitly evicts whichever cell was playing before, so at most one
/// `AVPlayer` is ever alive in the grid.
struct VideoCell: View {
    let item: MediaItem
    let targetPixels: CGFloat
    let cardAspectRatio: CGFloat

    @Environment(BrowserModel.self) private var model

    @State private var poster: NSImage?
    @State private var storyboard: VideoPreviewService.Storyboard?
    @State private var metadata: MediaMetadataService.Metadata?
    @State private var didFail = false
    @State private var playback: VideoPlayback?
    @State private var hoverFraction: Double?
    @State private var hoverWidth: CGFloat = 0
    @State private var shouldLoadStoryboard = false
    @State private var cardSize: CGSize = .zero

    private var isActive: Bool { model.playingVideoID == item.id }

    private var isSelected: Bool { model.selectedItemIDs.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaCardBackground(isSelected: isSelected && !hasVisualContent) {
                content
            }
            .aspectRatio(cardAspectRatio, contentMode: .fit)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                cardSize = size
            }
            .selectableCell(item, model: model)

            MediaCaption(title: item.name, subtitle: subtitle, isFavorite: item.isFavorite, tags: item.tags)
                .padding(.leading, captionLeadingInset)
        }
        .mediaItemInteractions(item, model: model, draggable: playback == nil)
        .dropDestination(for: URL.self) { urls, _ in
            guard model.isCollectionSelected, model.sortKey == .manual else { return false }
            model.reorderCollectionURLs(urls, before: item)
            return urls.count == 1
        }
        .task(id: posterTaskID) {
            await loadPoster()
        }
        .task(id: item.contentVersion) {
            await loadMetadata()
        }
        .task(id: storyboardTaskID) {
            await loadStoryboard()
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
            MediaThumbnailSurface(aspectRatio: mediaAspectRatio, isSelected: isSelected) {
                VideoPlayerView(player: playback.player, controlsStyle: .inline, refusesKeyboardFocus: true)
            }
        } else if poster != nil || storyboard != nil {
            MediaThumbnailSurface(aspectRatio: mediaAspectRatio, isSelected: isSelected) {
                scrubbablePoster
            }
        } else if didFail {
            PreviewUnavailable()
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var hasVisualContent: Bool {
        playback != nil || poster != nil || storyboard != nil
    }

    private var mediaAspectRatio: CGFloat {
        if let frame = displayedFrame, frame.size.height > 0 {
            return frame.size.width / frame.size.height
        }
        if let width = metadata?.width, let height = metadata?.height, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        return cardAspectRatio
    }

    private var captionLeadingInset: CGFloat {
        MediaThumbnailLayout.contentLeadingInset(
            aspectRatio: mediaAspectRatio,
            container: cardSize
        )
    }

    /// Poster or hover-scrub frame, with a play button. Horizontal mouse position
    /// selects the nearest cached storyboard frame rather than seeking a player
    /// (spec section 13).
    private var scrubbablePoster: some View {
        ZStack(alignment: .bottomLeading) {
            if let frame = displayedFrame {
                Image(nsImage: frame)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            }

            if let hoverFraction {
                Text(hoverTimecode(hoverFraction))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            hoverWidth = width
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                shouldLoadStoryboard = true
                guard hoverWidth > 0 else { return }
                hoverFraction = min(max(location.x / hoverWidth, 0), 1)
            case .ended:
                hoverFraction = nil
            }
        }
        .overlay(alignment: .bottom) {
            if let hoverFraction {
                GeometryReader { geo in
                    Rectangle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 2, height: geo.size.height)
                        .position(
                            x: min(max(geo.size.width * hoverFraction, 1), geo.size.width - 1),
                            y: geo.size.height / 2
                        )
                }
                .frame(height: 3)
                .allowsHitTesting(false)
            }
        }
        .overlay {
            Button {
                model.selectItem(item)
                model.playingVideoID = item.id
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .shadow(radius: 4)
                    .opacity(hoverFraction == nil ? 1 : 0.35)
            }
            .buttonStyle(.plain)
            .help("Play inline")
        }
    }

    private var displayedFrame: NSImage? {
        if let hoverFraction, let frames = storyboard?.frames, !frames.isEmpty {
            let index = min(frames.count - 1, max(0, Int(hoverFraction * Double(frames.count))))
            return frames[index]
        }
        return poster
    }

    private func hoverTimecode(_ fraction: Double) -> String {
        let duration = storyboard?.duration ?? metadata?.duration ?? 0
        return MediaFormatting.clock(duration * fraction) ?? "0:00"
    }

    private var subtitle: String? {
        MediaFormatting.detailLine([
            MediaFormatting.duration(metadata?.duration),
            MediaFormatting.dimensions(width: metadata?.width, height: metadata?.height),
        ]) ?? MediaFormatting.fileSize(item.fileSize)
    }

    /// Re-run poster generation when either the file or the size bucket changes.
    private var posterTaskID: String {
        "\(item.contentVersion)|\(Int(targetPixels))"
    }

    private var storyboardTaskID: String {
        shouldLoadStoryboard ? "\(item.contentVersion)|sb|\(Int(targetPixels))" : "idle"
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

    private func loadStoryboard() async {
        guard shouldLoadStoryboard else { return }
        let result = await VideoPreviewService.shared.storyboard(for: item.url, targetPixels: targetPixels)
        guard !Task.isCancelled else { return }
        storyboard = result
    }

    private func loadMetadata() async {
        let result = await MediaMetadataService.shared.metadata(for: item.url)
        guard !Task.isCancelled else { return }
        metadata = result
    }

    // MARK: - Playback

    private func startPlayback() {
        guard playback == nil else { return }
        hoverFraction = nil
        let controller = VideoPlayback(url: item.url)
        playback = controller
        controller.play()
    }

    private func stopPlayback() {
        playback?.tearDown()
        playback = nil
    }
}

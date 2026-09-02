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
/// Maximize and close live in the window toolbar (`ImageViewerToolbar`).
struct MediaViewer: View {
    let item: MediaItem

    @Environment(BrowserModel.self) private var model

    /// Non-nil only while a video is being viewed. Owned here rather than in a
    /// child view so the Space shortcut can drive it.
    @State private var playback: VideoPlayback?

    var body: some View {
        Group {
            if model.isComparingImages {
                viewerContent
            } else {
                viewerContent
                    .mediaItemInteractions(item, model: model, draggable: false)
            }
        }
        .preferredColorScheme(.light)
        .task(id: item.contentVersion) {
            preparePlayback()
        }
        .onChange(of: model.isComparingImages) { _, comparing in
            if comparing {
                teardownPlayback()
            } else {
                preparePlayback()
            }
        }
        .onDisappear {
            teardownPlayback()
        }
    }

    private var viewerContent: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            media
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, model.isComparingImages ? 104 : 72)

            chrome
            shortcuts
        }
    }

    @ViewBuilder
    private var media: some View {
        if model.isComparingImages {
            ImageComparisonGrid()
        } else {
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
                // Audio is never opened here; it lives in the list plus inspector.
                EmptyView()
            }
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
            Spacer()
                .allowsHitTesting(false)

            if model.isComparingImages {
                ComparisonThumbnailStrip()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
            } else if !model.isCropping {
                HStack(spacing: 12) {
                    navigationButton(
                        systemImage: "chevron.left",
                        shortcut: .leftArrow,
                        enabled: model.canShowPreviousInViewer,
                        help: "Previous (←)"
                    ) {
                        model.showPreviousInViewer()
                    }

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
                .background(.black.opacity(0.06), in: Capsule())
                .padding(.bottom, 16)
            }
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
                .foregroundStyle(enabled ? .primary : Color.primary.opacity(0.25))
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
            // Space plays/pauses video; on a still it closes, like Quick Look
            // (spec section 16). ⇧Space toggles image comparison. While
            // cropping, both are ignored so they cannot dismiss the guide.
            Button("Space") {
                if model.isCropping { return }
                if model.isComparingImages {
                    model.closeViewer()
                    return
                }
                if playback != nil {
                    playback?.togglePlayPause()
                } else {
                    model.closeViewer()
                }
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Compare Images") {
                if model.isCropping { return }
                model.toggleImageComparison()
            }
            .keyboardShortcut(.space, modifiers: .shift)

            Button("Play/Pause") {
                playback?.togglePlayPause()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(playback == nil || model.isCropping || model.isComparingImages)

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

// MARK: - Image comparison

private struct ImageComparisonGrid: View {
    @Environment(BrowserModel.self) private var model

    private let spacing: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let layout = model.compareLayout
            let width = max(
                0,
                (geometry.size.width - CGFloat(layout.columns - 1) * spacing)
                    / CGFloat(layout.columns)
            )
            let height = max(
                0,
                (geometry.size.height - CGFloat(layout.rows - 1) * spacing)
                    / CGFloat(layout.rows)
            )
            let images = Dictionary(uniqueKeysWithValues: model.comparisonImages.map { ($0.id, $0) })

            VStack(spacing: spacing) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<layout.columns, id: \.self) { column in
                            let index = row * layout.columns + column
                            let item = model.compareSlotItemIDs.indices.contains(index)
                                ? images[model.compareSlotItemIDs[index]]
                                : nil
                            ComparisonImageCell(item: item, slotIndex: index)
                                .frame(width: width, height: height)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct ComparisonImageCell: View {
    let item: MediaItem?
    let slotIndex: Int

    @Environment(BrowserModel.self) private var model
    @State private var isDropTarget = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.035))

            if let item {
                ComparisonLoadedImage(item: item, targetPixels: 3072)
                    .padding(8)

                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
                    .allowsHitTesting(false)
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title2)
                    Text("Drop an image")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isDropTarget ? Color.accentColor : Color.primary.opacity(0.10),
                    lineWidth: isDropTarget ? 2 : 1
                )
        }
        .dropDestination(for: String.self) { itemIDs, _ in
            guard let itemID = itemIDs.first,
                  model.compareItemIDs.contains(itemID)
            else { return false }
            model.assignComparisonImage(itemID, toSlot: slotIndex)
            return true
        } isTargeted: { isDropTarget = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.map { "Comparison image \($0.name)" } ?? "Empty comparison cell")
    }
}

private struct ComparisonThumbnailStrip: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.comparisonImages) { item in
                        ComparisonThumbnail(
                            item: item,
                            isActive: model.compareSlotItemIDs.contains(item.id)
                        )
                        .draggable(item.id)
                    }
                }
                .padding(6)
                .frame(minWidth: geometry.size.width)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: 66)
        .background(.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.08))
        }
        .frame(maxWidth: 720)
    }
}

private struct ComparisonThumbnail: View {
    let item: MediaItem
    let isActive: Bool

    var body: some View {
        ComparisonLoadedImage(item: item, targetPixels: 192)
            .frame(width: 76, height: 54)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        Color.primary.opacity(isActive ? 0.32 : 0.10),
                        lineWidth: 1
                    )
            }
        .help(item.name)
        .accessibilityLabel("\(item.name), \(isActive ? "active in comparison" : "not active")")
    }
}

private struct ComparisonLoadedImage: View {
    let item: MediaItem
    let targetPixels: CGFloat

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
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(item.contentVersion)|\(Int(targetPixels))") {
            image = nil
            didFail = false
            let result = await ThumbnailService.shared.thumbnail(
                for: item.url,
                targetPixels: targetPixels
            )
            guard !Task.isCancelled else { return }
            image = result?.image
            didFail = result == nil
        }
    }
}

// MARK: - Image

/// Full-viewer still. A 2048 px rendition appears first so the window is not
/// blank while the sharper 8192 px image (enough for 100% on typical photos)
/// finishes decoding off the main thread (spec sections 17 and 23).
private struct ViewerImage: View {
    let item: MediaItem

    @State private var image: NSImage?
    @State private var nativeSize: CGSize = .zero
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image, nativeSize: displaySize)
                    .id(item.id)
            } else if didFail {
                PreviewUnavailable()
            } else {
                ProgressView()
            }
        }
        .task(id: item.contentVersion) {
            await load()
        }
    }

    private var displaySize: CGSize {
        nativeSize.width > 0 ? nativeSize : (image?.size ?? .zero)
    }

    private func load() async {
        didFail = false
        image = nil
        nativeSize = .zero

        let preview = await ThumbnailService.shared.thumbnail(for: item.url, targetPixels: 2048)
        guard !Task.isCancelled else { return }
        if let preview {
            image = preview.image
            if let width = preview.pixelWidth, let height = preview.pixelHeight {
                nativeSize = CGSize(width: width, height: height)
            }
        } else {
            didFail = true
            return
        }

        let full = await ThumbnailService.shared.thumbnail(for: item.url, targetPixels: 8192)
        guard !Task.isCancelled else { return }
        if let full {
            image = full.image
            if let width = full.pixelWidth, let height = full.pixelHeight {
                nativeSize = CGSize(width: width, height: height)
            }
        }
    }
}

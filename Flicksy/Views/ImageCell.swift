//
//  ImageCell.swift
//  MediaBrowser
//

import SwiftUI

/// A grid cell showing an asynchronously generated image thumbnail.
///
/// The thumbnail is requested inside `.task(id:)`, so the work is automatically
/// cancelled when the cell scrolls off-screen or the target size changes — the
/// grid never blocks the main thread decoding images (spec sections 10 and 23).
struct ImageCell: View {
    let item: MediaItem
    let targetPixels: CGFloat
    let cardAspectRatio: CGFloat

    @Environment(BrowserModel.self) private var model

    @State private var image: NSImage?
    @State private var pixelWidth: Int?
    @State private var pixelHeight: Int?
    @State private var didFail = false
    @State private var cardSize: CGSize = .zero

    private var isSelected: Bool { model.selectedItemIDs.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaCardBackground(isSelected: isSelected && image == nil) {
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
        .mediaItemInteractions(item, model: model)
        .dropDestination(for: URL.self) { urls, _ in
            guard model.isCollectionSelected, model.sortKey == .manual else { return false }
            model.reorderCollectionURLs(urls, before: item)
            return urls.count == 1
        }
        .task(id: taskID) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            MediaThumbnailSurface(
                aspectRatio: imageAspectRatio(image),
                isSelected: isSelected
            ) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            }
        } else if didFail {
            PreviewUnavailable()
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func imageAspectRatio(_ image: NSImage) -> CGFloat {
        guard image.size.height > 0 else { return cardAspectRatio }
        return image.size.width / image.size.height
    }

    private var captionLeadingInset: CGFloat {
        MediaThumbnailLayout.contentLeadingInset(
            aspectRatio: image.map(imageAspectRatio) ?? cardAspectRatio,
            container: cardSize
        )
    }

    private var subtitle: String? {
        MediaFormatting.dimensions(
            width: pixelWidth ?? item.width,
            height: pixelHeight ?? item.height
        )
            ?? MediaFormatting.fileSize(item.fileSize)
    }

    /// Re-run the load when either the file or the requested size bucket changes.
    private var taskID: String {
        "\(item.contentVersion)|\(Int(targetPixels))"
    }

    private func loadThumbnail() async {
        didFail = false
        let result = await ThumbnailService.shared.thumbnail(for: item.url, targetPixels: targetPixels)
        guard !Task.isCancelled else { return }
        if let result {
            image = result.image
            pixelWidth = result.pixelWidth
            pixelHeight = result.pixelHeight
        } else {
            didFail = true
        }
    }
}

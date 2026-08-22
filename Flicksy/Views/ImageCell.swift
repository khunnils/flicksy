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
    @State private var didFail = false

    private var isSelected: Bool { model.selectedItemIDs.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaCardBackground(isSelected: isSelected) {
                content
            }
            .aspectRatio(cardAspectRatio, contentMode: .fit)
            .selectableCell(item, model: model)

            MediaCaption(title: item.name, subtitle: subtitle)
        }
        .task(id: taskID) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .padding(2)
        } else if didFail {
            PreviewUnavailable()
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var subtitle: String? {
        MediaFormatting.dimensions(width: item.width, height: item.height)
            ?? MediaFormatting.fileSize(item.fileSize)
    }

    /// Re-run the load when either the file or the requested size bucket changes.
    private var taskID: String {
        "\(item.url.path)|\(Int(targetPixels))"
    }

    private func loadThumbnail() async {
        didFail = false
        let result = await ThumbnailService.shared.thumbnail(for: item.url, targetPixels: targetPixels)
        guard !Task.isCancelled else { return }
        if let result {
            image = result.image
        } else {
            didFail = true
        }
    }
}

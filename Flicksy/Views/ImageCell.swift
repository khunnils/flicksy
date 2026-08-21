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

    @Environment(BrowserModel.self) private var model

    @State private var image: NSImage?
    @State private var pixelSize: (width: Int, height: Int)?
    @State private var didFail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaCardBackground {
                content
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
            .onTapGesture {
                model.openViewer(item)
            }

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
        if let pixelSize {
            return "\(pixelSize.width)×\(pixelSize.height)"
        }
        return MediaFormatting.fileSize(item.fileSize)
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
            if let w = result.pixelWidth, let h = result.pixelHeight {
                pixelSize = (w, h)
            }
        } else {
            didFail = true
        }
    }
}

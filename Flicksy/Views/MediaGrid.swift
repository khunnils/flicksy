//
//  MediaGrid.swift
//  MediaBrowser
//

import SwiftUI

/// Lazy grid of image and video cells (spec sections 8, 9 and 23).
///
/// Column count is derived from `thumbnailSize` so the layout reflows as the
/// user zooms rather than snapping between a few fixed grids.
struct MediaGrid: View {
    let items: [MediaItem]
    let thumbnailSize: CGFloat
    let cardAspectRatio: CGFloat

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSize), spacing: 12)]
    }

    /// Decode target scales with on-screen cell size. The thumbnail services
    /// quantize this into buckets so nearby zoom levels reuse the cache.
    private var targetPixels: CGFloat {
        switch thumbnailSize {
        case ..<120: return 256
        case ..<240: return 512
        default: return 1024
        }
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(items) { item in
                switch item.type {
                case .image:
                    ImageCell(
                        item: item,
                        targetPixels: targetPixels,
                        cardAspectRatio: cardAspectRatio
                    )
                case .video:
                    VideoCell(
                        item: item,
                        targetPixels: targetPixels,
                        cardAspectRatio: cardAspectRatio
                    )
                case .audio:
                    EmptyView() // Audio is rendered in its own full-width section.
                }
            }
        }
    }
}

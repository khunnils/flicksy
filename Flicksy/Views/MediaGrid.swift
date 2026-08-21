//
//  MediaGrid.swift
//  MediaBrowser
//

import SwiftUI

/// Lazy grid of image and video cells (spec sections 8, 9 and 23).
struct MediaGrid: View {
    let items: [MediaItem]
    let columns: Int

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columns)
    }

    /// Target thumbnail size scales inversely with column count: fewer, larger
    /// cells warrant larger thumbnails. The service quantizes this into buckets.
    private var targetPixels: CGFloat {
        switch columns {
        case 1, 2: return 1024
        default: return 600
        }
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(items) { item in
                switch item.type {
                case .image:
                    ImageCell(item: item, targetPixels: targetPixels)
                case .video:
                    VideoCell(item: item)
                case .audio:
                    EmptyView() // Audio is rendered in its own full-width section.
                }
            }
        }
    }
}

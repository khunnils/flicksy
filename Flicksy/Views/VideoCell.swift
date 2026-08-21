//
//  VideoCell.swift
//  MediaBrowser
//

import SwiftUI

/// Milestone 1 placeholder for a video item.
///
/// The smart sidebar and grid already detect and list videos, but real poster
/// frames and inline `AVPlayer` playback are Milestone 2. This cell shows a static
/// placeholder so videos are visible without creating any playback resources
/// (spec sections 11 and 12). It intentionally mirrors `ImageCell`'s layout so
/// swapping in a poster frame later is a localized change.
struct VideoCell: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaCardBackground {
                ZStack {
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white, .black.opacity(0.4))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .aspectRatio(1, contentMode: .fit)

            MediaCaption(title: item.name, subtitle: MediaFormatting.fileSize(item.fileSize))
        }
    }
}

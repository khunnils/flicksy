//
//  AudioSection.swift
//  MediaBrowser
//

import SwiftUI

/// Full-width list of audio rows shown beneath the image/video grid (spec
/// section 8). Audio is never represented as square thumbnail cards.
struct AudioSection: View {
    let items: [MediaItem]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items) { item in
                AudioRow(item: item)
            }
        }
    }
}

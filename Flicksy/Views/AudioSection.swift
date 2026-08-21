//
//  AudioSection.swift
//  MediaBrowser
//

import SwiftUI

/// Full-width list of audio rows shown beneath the image/video grid (spec
/// section 8). Audio is never represented as square thumbnail cards.
///
/// Lazy so that a folder of hundreds of sounds only generates waveforms for the
/// rows the user has actually scrolled to (spec section 23, rule 3).
struct AudioSection: View {
    let items: [MediaItem]

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(items) { item in
                AudioRow(item: item)
            }
        }
    }
}

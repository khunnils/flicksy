//
//  AudioSection.swift
//  MediaBrowser
//

import SwiftUI

/// Audio media shown either as compact Finder-style icons or full waveform rows.
/// Both layouts are lazy so off-screen files do not create playback or waveform
/// resources.
struct AudioSection: View {
    let items: [MediaItem]
    let viewMode: AudioViewMode

    var body: some View {
        switch viewMode {
        case .icons:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104, maximum: 116), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(items) { item in
                    AudioIconCell(item: item)
                }
            }
        case .waveforms:
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    AudioRow(item: item)
                }
            }
        }
    }
}

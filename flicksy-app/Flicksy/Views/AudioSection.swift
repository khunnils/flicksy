//
//  AudioSection.swift
//  MediaBrowser
//

import SwiftUI

/// Audio media shown as a metadata list or full waveform rows. Both layouts are
/// lazy so off-screen files do not create playback or waveform resources.
struct AudioSection: View {
    let items: [MediaItem]
    let viewMode: AudioViewMode
    let selectionCoordinateSpace: String

    var body: some View {
        switch viewMode {
        case .list:
            AudioMetadataList(
                items: items,
                selectionCoordinateSpace: selectionCoordinateSpace
            )
        case .waveforms:
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    AudioRow(item: item)
                        .id(item.id)
                        .reportSelectionFrame(
                            for: item,
                            coordinateSpace: selectionCoordinateSpace
                        )
                }
            }
        }
    }
}

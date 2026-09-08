//
//  AudioSection.swift
//  MediaBrowser
//

import SwiftUI

/// Waveform-first sound asset browsing with a shared listening workspace.
struct AudioSection: View {
    let items: [MediaItem]
    let selectionCoordinateSpace: String
    let onSelectionFrameChange: (MediaItem.ID, UUID, CGRect?) -> Void

    var body: some View {
        AudioMetadataList(
            items: items,
            selectionCoordinateSpace: selectionCoordinateSpace,
            onSelectionFrameChange: onSelectionFrameChange
        )
    }
}

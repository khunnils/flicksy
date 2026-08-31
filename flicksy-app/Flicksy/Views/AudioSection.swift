//
//  AudioSection.swift
//  MediaBrowser
//

import SwiftUI

/// Audio media shown as a metadata list. The selected clip's waveform lives in
/// the bottom inspector, not in a second layout mode.
struct AudioSection: View {
    let items: [MediaItem]
    let selectedItemIDs: Set<MediaItem.ID>
    let selectionCoordinateSpace: String
    let onSelectionFrameChange: (MediaItem.ID, UUID, CGRect?) -> Void

    var body: some View {
        AudioMetadataList(
            items: items,
            selectedItemIDs: selectedItemIDs,
            selectionCoordinateSpace: selectionCoordinateSpace,
            onSelectionFrameChange: onSelectionFrameChange
        )
    }
}

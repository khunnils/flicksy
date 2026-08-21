//
//  MediaBrowserView.swift
//  MediaBrowser
//

import SwiftUI

/// The main content area: an image/video grid section followed by a full-width
/// audio section (spec section 8).
struct MediaBrowserView: View {
    @Environment(BrowserModel.self) private var model

    private var visualItems: [MediaItem] {
        model.mediaItems.filter { $0.type == .image || $0.type == .video }
    }

    private var audioItems: [MediaItem] {
        model.mediaItems.filter { $0.type == .audio }
    }

    var body: some View {
        Group {
            if model.selectedFolderID == nil {
                ContentUnavailableView(
                    "No Folder Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select a folder in the sidebar to browse its media.")
                )
            } else if model.mediaItems.isEmpty {
                if model.isLoadingMedia {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "No Media",
                        systemImage: "photo.on.rectangle",
                        description: Text("This folder does not contain any supported media.")
                    )
                }
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !visualItems.isEmpty {
                    section(title: "IMAGES & VIDEO") {
                        MediaGrid(items: visualItems, columns: model.gridColumns)
                    }
                }

                if !audioItems.isEmpty {
                    section(title: "AUDIO") {
                        AudioSection(items: audioItems)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
            content()
        }
    }
}

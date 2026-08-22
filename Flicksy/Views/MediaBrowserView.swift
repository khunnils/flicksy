//
//  MediaBrowserView.swift
//  MediaBrowser
//

import SwiftUI

/// The main content area. Images/video and audio live on separate tabs so a
/// stills review never scrolls past a waveform list, and vice versa.
struct MediaBrowserView: View {
    @Environment(BrowserModel.self) private var model

    /// Whether the browser owns keyboard focus. Only when focused does it handle
    /// arrows/Space/Enter/Delete, so the folder sidebar keeps its own arrow
    /// navigation while it is the focused pane.
    @FocusState private var browserFocused: Bool

    /// Search has its own focus state so keystrokes edit the query instead of
    /// triggering grid navigation and media commands.
    @FocusState private var searchFieldFocused: Bool

    /// Number of columns the visual grid currently lays out, derived from the
    /// available width and the thumbnail size. Drives Up/Down arrow movement.
    @State private var columns: Int = 1

    /// Number of columns in the compact audio layout, used for row-wise keyboard
    /// navigation. Waveform mode always behaves as a single column.
    @State private var audioColumns: Int = 1

    var body: some View {
        @Bindable var model = model

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
            } else if model.hasActiveSearch && model.visualItems.isEmpty && model.audioItems.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No media matches \u{201c}\(model.searchQuery)\u{201d}.")
                )
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable(model.selectedFolderID != nil)
        .focusEffectDisabled()
        .focused($browserFocused)
        .searchable(
            text: $model.searchQuery,
            isPresented: $model.isSearchPresented,
            placement: .toolbar,
            prompt: "Search Media"
        )
        .searchFocused($searchFieldFocused)
        .onKeyPress { handleKey($0) }
        .onChange(of: searchFieldFocused) { _, focused in
            model.isSearchFieldFocused = focused
        }
        .onChange(of: model.focusedItemID) { _, id in
            // Clicking or arrowing to an item pulls focus into the browser so its
            // key handling takes over from the sidebar.
            if id != nil { browserFocused = true }
        }
    }

    private var content: some View {
        Group {
            switch model.libraryTab {
            case .visual:
                if model.visualItems.isEmpty {
                    emptyTab(
                        title: "No Images or Video",
                        systemImage: "photo.on.rectangle",
                        otherTabHint: model.audioItems.isEmpty ? nil : "Matching audio is in the Audio tab."
                    )
                } else {
                    scrollingPane(visualGrid)
                }
            case .audio:
                if model.audioItems.isEmpty {
                    emptyTab(
                        title: "No Audio",
                        systemImage: "waveform",
                        otherTabHint: model.visualItems.isEmpty ? nil : "Matching images and video are in the Images & Video tab."
                    )
                } else {
                    scrollingPane(audioList)
                }
            }
        }
    }

    private func scrollingPane<Content: View>(_ content: Content) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        columns = columnCount(forWidth: width)
                        audioColumns = audioColumnCount(forWidth: width)
                    }
            }
            .onChange(of: model.focusedItemID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var visualGrid: some View {
        MediaGrid(
            items: model.visualItems,
            thumbnailSize: CGFloat(model.thumbnailSize),
            cardAspectRatio: CGFloat(model.cardAspectRatio)
        )
    }

    private var audioList: some View {
        AudioSection(items: model.audioItems, viewMode: model.audioViewMode)
    }

    private func emptyTab(title: String, systemImage: String, otherTabHint: String?) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let otherTabHint {
                Text(otherTabHint)
            } else if model.hasActiveSearch {
                Text("No media matches \u{201c}\(model.searchQuery)\u{201d}.")
            } else {
                Text("This folder does not contain this kind of media.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Mirror the grid's adaptive-column math so Up/Down move by a full row.
    private func columnCount(forWidth width: CGFloat) -> Int {
        let itemWidth = CGFloat(model.thumbnailSize)
        let spacing: CGFloat = 12
        let available = max(0, width - 32) // matches the outer .padding(16)
        return max(1, Int((available + spacing) / (itemWidth + spacing)))
    }

    private func audioColumnCount(forWidth width: CGFloat) -> Int {
        let spacing: CGFloat = 12
        let minimumItemWidth: CGFloat = 104
        let available = max(0, width - 32)
        return max(1, Int((available + spacing) / (minimumItemWidth + spacing)))
    }

    private var navigationColumns: Int {
        switch model.libraryTab {
        case .visual:
            columns
        case .audio:
            model.audioViewMode == .icons ? audioColumns : 1
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // While the viewer is open its own shortcuts (arrows, Space, Enter, Esc)
        // take over, so the grid stays out of the way.
        guard model.viewerItemID == nil, !searchFieldFocused else { return .ignored }

        let extend = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow:
            model.moveSelection(.left, columns: navigationColumns, extending: extend)
        case .rightArrow:
            model.moveSelection(.right, columns: navigationColumns, extending: extend)
        case .upArrow:
            model.moveSelection(.up, columns: navigationColumns, extending: extend)
        case .downArrow:
            model.moveSelection(.down, columns: navigationColumns, extending: extend)
        case .space:
            model.openPreview()
        case .return:
            model.togglePlaybackOfFocusedItem()
        case .delete, .deleteForward:
            model.moveSelectedItemsToTrash()
        default:
            return .ignored
        }
        return .handled
    }
}

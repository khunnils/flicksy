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

    /// Available browser width, retained so keyboard navigation can derive the
    /// current column count after toolbar or pinch zoom changes the tile size.
    @State private var browserWidth: CGFloat = 0

    /// Live magnification while a trackpad pinch is in progress. The persisted
    /// thumbnail size is committed only when the gesture ends.
    @GestureState private var gridMagnification: CGFloat = 1

    var body: some View {
        @Bindable var model = model

        Group {
            if !model.hasSelectedSource {
                ContentUnavailableView(
                    "No Source Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select Clipboard or a folder in the sidebar to browse media.")
                )
            } else if model.mediaItems.isEmpty {
                if model.isLoadingMedia {
                    ProgressView()
                } else if model.isClipboardSelected {
                    ContentUnavailableView(
                        "Clipboard Is Empty",
                        systemImage: "clipboard",
                        description: Text("Copy an image while Flicksy is running. Recent clipboard images are saved here automatically.")
                    )
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
        .focusable(model.hasSelectedSource)
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
                        .simultaneousGesture(gridMagnifyGesture)
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
                        browserWidth = width
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
            thumbnailSize: effectiveThumbnailSize,
            cardAspectRatio: CGFloat(model.cardAspectRatio)
        )
    }

    private var effectiveThumbnailSize: CGFloat {
        CGFloat(BrowserModel.clampedThumbnailSize(
            model.thumbnailSize * Double(gridMagnification)
        ))
    }

    private var gridMagnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($gridMagnification) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                model.thumbnailSize = BrowserModel.clampedThumbnailSize(
                    model.thumbnailSize * Double(value.magnification)
                )
            }
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

    private var navigationColumns: Int {
        switch model.libraryTab {
        case .visual:
            columnCount(forWidth: browserWidth)
        case .audio:
            1
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

//
//  MediaBrowserView.swift
//  MediaBrowser
//

import SwiftUI

/// The main content area: an image/video grid section followed by a full-width
/// audio section (spec section 8).
struct MediaBrowserView: View {
    @Environment(BrowserModel.self) private var model

    /// Whether the browser owns keyboard focus. Only when focused does it handle
    /// arrows/Space/Enter/Delete, so the folder sidebar keeps its own arrow
    /// navigation while it is the focused pane.
    @FocusState private var browserFocused: Bool

    /// Number of columns the visual grid currently lays out, derived from the
    /// available width and the thumbnail size. Drives Up/Down arrow movement.
    @State private var columns: Int = 1

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
        .contentShape(Rectangle())
        .focusable(model.selectedFolderID != nil)
        .focusEffectDisabled()
        .focused($browserFocused)
        .onKeyPress { handleKey($0) }
        .onChange(of: model.focusedItemID) { _, id in
            // Clicking or arrowing to an item pulls focus into the browser so its
            // key handling takes over from the sidebar.
            if id != nil { browserFocused = true }
        }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !model.visualItems.isEmpty {
                        section(title: "IMAGES & VIDEO") {
                            MediaGrid(items: model.visualItems, thumbnailSize: CGFloat(model.thumbnailSize))
                        }
                    }

                    if !model.audioItems.isEmpty {
                        section(title: "AUDIO") {
                            AudioSection(items: model.audioItems)
                        }
                    }
                }
                .padding(16)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    columns = columnCount(forWidth: width)
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

    /// Mirror the grid's adaptive-column math so Up/Down move by a full row.
    private func columnCount(forWidth width: CGFloat) -> Int {
        let itemWidth = CGFloat(model.thumbnailSize)
        let spacing: CGFloat = 12
        let available = max(0, width - 32) // matches the outer .padding(16)
        return max(1, Int((available + spacing) / (itemWidth + spacing)))
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // While the viewer is open its own shortcuts (arrows, Space, Enter, Esc)
        // take over, so the grid stays out of the way.
        guard model.viewerItemID == nil else { return .ignored }

        let extend = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow:
            model.moveSelection(.left, columns: columns, extending: extend)
        case .rightArrow:
            model.moveSelection(.right, columns: columns, extending: extend)
        case .upArrow:
            model.moveSelection(.up, columns: columns, extending: extend)
        case .downArrow:
            model.moveSelection(.down, columns: columns, extending: extend)
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

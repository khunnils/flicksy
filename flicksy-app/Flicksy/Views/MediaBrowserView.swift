//
//  MediaBrowserView.swift
//  MediaBrowser
//

import AppKit
import SwiftUI

/// The main content area. All media can be scanned in one metadata list, while
/// images/video and audio retain their purpose-built views.
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

    /// Keyboard moves set this so the focused cell is scrolled into view. Clicks
    /// leave it false — selecting an already-visible tile should not recenter it.
    @State private var shouldScrollFocusIntoView = false

    /// Cell frames and transient state for Finder-style empty-space marquee
    /// selection. The gesture deliberately ignores drags that begin on an item,
    /// leaving those to the native file-drag interaction on each cell.
    @State private var selectionFrames: [MediaItem.ID: SelectionFrameRegistration] = [:]
    @State private var marqueeFrames: [MediaItem.ID: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeRect: CGRect?
    @State private var marqueeBaseSelection: Set<MediaItem.ID> = []
    @State private var marqueeMode: MarqueeMode = .replacing
    @State private var isIgnoringMarqueeDrag = false

    private static let selectionCoordinateSpace = "media-browser-selection"

    var body: some View {
        @Bindable var model = model

        Group {
            if !model.hasSelectedSource {
                ContentUnavailableView(
                    "No Source Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select Clipboard or a folder in the sidebar to browse media.")
                )
            } else if model.mediaItems.isEmpty && !model.missingCollectionItems.isEmpty {
                MissingCollectionItemsView(items: model.missingCollectionItems)
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
        .safeAreaInset(edge: .top) {
            if !model.mediaItems.isEmpty, !model.missingCollectionItems.isEmpty {
                MissingCollectionItemsView(items: model.missingCollectionItems, compact: true)
            }
        }
        .contentShape(Rectangle())
        .focusable(model.hasSelectedSource)
        .focusEffectDisabled()
        .focused($browserFocused)
        .modifier(BrowserSearch(
            text: $model.searchQuery,
            isPresented: $model.isSearchPresented,
            isEnabled: model.viewerItemID == nil,
            searchFieldFocused: $searchFieldFocused
        ))
        .onKeyPress { handleKey($0) }
        .onChange(of: searchFieldFocused) { _, focused in
            model.isSearchFieldFocused = focused
        }
        .onChange(of: model.viewerItemID) { _, id in
            if id != nil { searchFieldFocused = false }
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
            case .all:
                if model.allItems.isEmpty {
                    emptyTab(
                        title: "No Media",
                        systemImage: "tray.full",
                        otherTabHint: nil
                    )
                } else {
                    scrollingPane(allList)
                }
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
                        .safeAreaInset(edge: .bottom) {
                            if let item = model.selectedAudioItem {
                                AudioInspectorPanel(item: item)
                            }
                        }
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
            .coordinateSpace(name: Self.selectionCoordinateSpace)
            .simultaneousGesture(marqueeSelectionGesture)
            .overlay {
                if let marqueeRect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.14))
                        .stroke(Color.accentColor.opacity(0.82), lineWidth: 1)
                        .frame(width: marqueeRect.width, height: marqueeRect.height)
                        .position(x: marqueeRect.midX, y: marqueeRect.midY)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .onChange(of: model.focusedItemID) { _, id in
                guard shouldScrollFocusIntoView, let id else { return }
                shouldScrollFocusIntoView = false
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
            cardAspectRatio: CGFloat(model.cardAspectRatio),
            selectionCoordinateSpace: Self.selectionCoordinateSpace,
            onSelectionFrameChange: { id, reporterID, frame in
                guard model.libraryTab == .visual else { return }
                updateSelectionFrame(id, reporterID: reporterID, source: .visual, frame: frame)
            }
        )
    }

    private var allList: some View {
        AllMetadataList(
            items: model.allItems,
            selectedItemIDs: model.selectedItemIDs,
            selectionCoordinateSpace: Self.selectionCoordinateSpace,
            onSelectionFrameChange: { id, reporterID, frame in
                guard model.libraryTab == .all else { return }
                updateSelectionFrame(id, reporterID: reporterID, source: .all, frame: frame)
            }
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
        AudioSection(
            items: model.audioItems,
            // Keep selection in this parent dependency graph. The inspector
            // already invalidates here; relying on a nested lazy list to observe
            // the model can leave its cached row backgrounds stale.
            selectedItemIDs: model.selectedItemIDs,
            selectionCoordinateSpace: Self.selectionCoordinateSpace,
            onSelectionFrameChange: { id, reporterID, frame in
                guard model.libraryTab == .audio else { return }
                updateSelectionFrame(id, reporterID: reporterID, source: .audio, frame: frame)
            }
        )
    }

    private var marqueeSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.selectionCoordinateSpace))
            .onChanged { value in
                if marqueeStart == nil, !isIgnoringMarqueeDrag {
                    let activeIDs = Set(model.orderedItems.map(\.id))
                    let activeFrames = selectionFrames
                        .filter {
                            activeIDs.contains($0.key)
                                && $0.value.source == activeSelectionFrameSource
                        }
                        .mapValues(\.frame)
                    let beganOnItem = activeFrames.values.contains { frame in
                        frame.insetBy(dx: -2, dy: -2).contains(value.startLocation)
                    }
                    guard !beganOnItem else {
                        isIgnoringMarqueeDrag = true
                        return
                    }

                    browserFocused = true
                    marqueeStart = value.startLocation
                    marqueeFrames = activeFrames
                    marqueeBaseSelection = model.selectedItemIDs

                    let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    if modifiers.contains(.command) || modifiers.contains(.control) {
                        marqueeMode = .toggling
                    } else if modifiers.contains(.shift) {
                        marqueeMode = .adding
                    } else {
                        marqueeMode = .replacing
                    }
                }

                guard let marqueeStart, !isIgnoringMarqueeDrag else { return }
                let rect = CGRect(
                    x: min(marqueeStart.x, value.location.x),
                    y: min(marqueeStart.y, value.location.y),
                    width: abs(value.location.x - marqueeStart.x),
                    height: abs(value.location.y - marqueeStart.y)
                )
                marqueeRect = rect

                let intersecting = Set(marqueeFrames.compactMap { id, frame in
                    rect.intersects(frame) ? id : nil
                })
                model.setMarqueeSelection(selectionForMarquee(intersecting))
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeRect = nil
                marqueeFrames = [:]
                marqueeBaseSelection = []
                isIgnoringMarqueeDrag = false
            }
    }

    private func updateSelectionFrame(
        _ id: MediaItem.ID,
        reporterID: UUID,
        source: SelectionFrameSource,
        frame: CGRect?
    ) {
        if let frame {
            selectionFrames[id] = SelectionFrameRegistration(
                reporterID: reporterID,
                source: source,
                frame: frame
            )
        } else if selectionFrames[id]?.reporterID == reporterID {
            selectionFrames.removeValue(forKey: id)
        }
    }

    private var activeSelectionFrameSource: SelectionFrameSource {
        switch model.libraryTab {
        case .all: .all
        case .visual: .visual
        case .audio: .audio
        }
    }

    private func selectionForMarquee(_ intersecting: Set<MediaItem.ID>) -> Set<MediaItem.ID> {
        switch marqueeMode {
        case .replacing:
            intersecting
        case .adding:
            marqueeBaseSelection.union(intersecting)
        case .toggling:
            marqueeBaseSelection.symmetricDifference(intersecting)
        }
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
        case .all:
            1
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
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .leftArrow:
            if command {
                guard model.canControlInspectorAudio else { return .ignored }
                model.requestAudioSeek(.start)
            } else if model.canControlInspectorAudio {
                model.requestAudioSeek(.rewind)
            } else {
                moveFocus(.left, extending: extend)
            }
        case .rightArrow:
            if command {
                guard model.canControlInspectorAudio else { return .ignored }
                model.requestAudioSeek(.end)
            } else if model.canControlInspectorAudio {
                model.requestAudioSeek(.forward)
            } else {
                moveFocus(.right, extending: extend)
            }
        case .upArrow:
            moveFocus(.up, extending: extend)
        case .downArrow:
            moveFocus(.down, extending: extend)
        case .space:
            if shouldSpaceTogglePlayback {
                model.togglePlaybackOfFocusedItem()
            } else {
                model.openPreview()
            }
        case .return:
            model.togglePlaybackOfFocusedItem()
        case .delete, .deleteForward:
            model.moveSelectedItemsToTrash()
        default:
            return .ignored
        }
        return .handled
    }

    private var shouldSpaceTogglePlayback: Bool {
        if model.libraryTab == .audio { return true }
        if let focusedItemID = model.focusedItemID,
           let item = model.orderedItems.first(where: { $0.id == focusedItemID }),
           item.type == .audio {
            return true
        }
        return model.selectedAudioItem != nil
    }

    private func moveFocus(_ direction: MoveDirection, extending: Bool) {
        let previous = model.focusedItemID
        shouldScrollFocusIntoView = true
        model.moveSelection(direction, columns: navigationColumns, extending: extending)
        if model.focusedItemID == previous {
            shouldScrollFocusIntoView = false
        }
    }
}

private enum MarqueeMode {
    case replacing
    case adding
    case toggling
}

private struct SelectionFrameRegistration {
    let reporterID: UUID
    let source: SelectionFrameSource
    let frame: CGRect
}

private enum SelectionFrameSource {
    case all
    case visual
    case audio
}

private struct MissingCollectionItemsView: View {
    @Environment(BrowserModel.self) private var model
    let items: [MissingCollectionItem]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(items.count) Missing \(items.count == 1 ? "Item" : "Items")", systemImage: "exclamationmark.triangle")
                .font(.headline)
            if !compact {
                Text("These originals moved outside the library or are unavailable.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items.prefix(compact ? 3 : items.count)) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1)
                        Text(item.lastKnownPath)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Locate…") { model.locateMissingCollectionItem(item) }
                    Button("Remove", role: .destructive) { model.removeMissingCollectionItem(item) }
                }
            }
            if compact, items.count > 3 {
                Text("And \(items.count - 3) more…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 10 : 20)
        .frame(maxWidth: compact ? .infinity : 600, alignment: .leading)
        .background(.bar)
    }
}

/// Toolbar search is attached only while the library is visible, so preview
/// does not inherit the search field.
private struct BrowserSearch: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    var isEnabled: Bool
    var searchFieldFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(
                    text: $text,
                    isPresented: $isPresented,
                    placement: .toolbar,
                    prompt: "Search Media"
                )
                .searchFocused(searchFieldFocused)
        } else {
            content
        }
    }
}

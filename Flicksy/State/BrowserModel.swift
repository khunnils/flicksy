//
//  BrowserModel.swift
//  MediaBrowser
//

import Foundation
import Observation

/// Grid navigation directions for keyboard selection movement.
enum MoveDirection {
    case left, right, up, down
}

/// The two presentations available for audio media.
enum AudioViewMode: String, CaseIterable {
    case icons
    case waveforms
}

/// The single source of truth for the browser UI.
///
/// Deliberately kept to plain `@Observable` state with no additional architectural
/// framework (spec section 21). Expensive filesystem work is delegated to
/// `FolderScanner`, which runs off the main actor; this class only owns the
/// resulting state and the tasks that produce it.
@Observable
@MainActor
final class BrowserModel {
    /// One pruned tree per authorized root folder, shown in the sidebar.
    private(set) var rootTrees: [MediaFolder] = []

    /// Selection is tracked by folder id (the folder's path) so it stays stable
    /// across rescans that rebuild the tree nodes.
    var selectedFolderID: MediaFolder.ID? {
        didSet {
            guard selectedFolderID != oldValue else { return }
            searchQuery = ""
            isSearchPresented = false
            isSearchFieldFocused = false
            loadMediaForSelection()
        }
    }

    /// Media directly contained in the selected folder.
    private(set) var mediaItems: [MediaItem] = []

    /// The current search text. Filtering is cheap filename matching over the
    /// already-loaded folder contents, so results update on every keystroke.
    var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            applySearchFilter()
        }
    }

    /// Drives programmatic activation of the native toolbar search field.
    var isSearchPresented = false

    /// Mirrored from the search field's focus state so browser-level commands do
    /// not consume text-editing shortcuts while the user is typing.
    var isSearchFieldFocused = false

    var hasActiveSearch: Bool { !normalizedSearchQuery.isEmpty }

    /// Audio defaults to compact Finder-style icons; a user's explicit choice is
    /// retained between launches.
    var audioViewMode: AudioViewMode {
        didSet {
            UserDefaults.standard.set(audioViewMode.rawValue, forKey: Self.audioViewModeKey)
        }
    }

    /// `mediaItems` filtered by `searchQuery` and split by presentation: images
    /// and videos share the grid while audio gets full-width rows (spec section
    /// 8). These are stored because views read them on every body evaluation.
    private(set) var visualItems: [MediaItem] = []
    private(set) var audioItems: [MediaItem] = []

    /// Shared width-to-height ratio for every card in the visual grid. It is
    /// derived from all images in the selected folder (not search results), so
    /// filtering never causes the grid to reflow.
    private(set) var cardAspectRatio: Double = 1

    /// The one grid cell permitted to hold a live `AVPlayer`.
    ///
    /// Playing a video assigns this, which implicitly tears down whatever was
    /// playing before — the invariant "at most one inline player exists" is
    /// therefore enforced by the state itself rather than by cells coordinating
    /// with each other (spec section 12).
    var playingVideoID: MediaItem.ID? {
        didSet {
            if playingVideoID != nil { playingAudioID = nil }
        }
    }

    /// The one audio row permitted to hold a live player (spec section 15).
    ///
    /// Kept separate from `playingVideoID` because an audio row stays selected and
    /// scrubbable while paused, but the two are mutually exclusive: hearing a clip
    /// and a sound effect at once tells you nothing about either.
    var playingAudioID: MediaItem.ID? {
        didSet {
            if playingAudioID != nil { playingVideoID = nil }
        }
    }

    /// The item shown in the focused full-screen viewer, if any (spec section 16).
    private(set) var viewerItemID: MediaItem.ID?

    /// Items the user has selected in the browser. Selection is independent of
    /// playback and viewer state: clicking selects (Finder-style) rather than
    /// opening, so the user can act on one or many items at once.
    var selectedItemIDs: Set<MediaItem.ID> = []

    /// The anchor for Shift-click / Shift-arrow range selection.
    var selectionAnchorID: MediaItem.ID?

    /// The keyboard cursor: the last item touched by a click or arrow move. Drives
    /// arrow navigation, Space preview and Enter playback.
    var focusedItemID: MediaItem.ID?

    private(set) var isScanning = false
    private(set) var isLoadingMedia = false

    /// A user-facing message when folders cannot be restored or read. Cleared once
    /// the situation is resolved (spec section 24).
    var loadError: String?

    /// Target thumbnail width in points. The grid fits as many columns as will
    /// accommodate this size; persisted between launches.
    var thumbnailSize: Double {
        didSet {
            let clamped = Self.clampedThumbnailSize(thumbnailSize)
            if clamped != thumbnailSize {
                thumbnailSize = clamped
                return
            }
            UserDefaults.standard.set(thumbnailSize, forKey: Self.thumbnailSizeKey)
        }
    }

    static let minThumbnailSize: Double = 80
    static let maxThumbnailSize: Double = 400
    static let defaultThumbnailSize: Double = 200
    static let thumbnailSizeStep: Double = 28

    static func clampedThumbnailSize(_ size: Double) -> Double {
        min(max(size, minThumbnailSize), maxThumbnailSize)
    }

    func zoomIn() {
        thumbnailSize = Self.clampedThumbnailSize(thumbnailSize + Self.thumbnailSizeStep)
    }

    func zoomOut() {
        thumbnailSize = Self.clampedThumbnailSize(thumbnailSize - Self.thumbnailSizeStep)
    }

    private static let thumbnailSizeKey = "thumbnailSize"
    private static let audioViewModeKey = "audioViewMode"

    private let rootStore = RootFolderStore()
    private var scanTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init() {
        let storedSize = UserDefaults.standard.object(forKey: Self.thumbnailSizeKey) as? Double
        thumbnailSize = storedSize.map(Self.clampedThumbnailSize) ?? Self.defaultThumbnailSize

        let storedAudioMode = UserDefaults.standard.string(forKey: Self.audioViewModeKey)
            .flatMap(AudioViewMode.init(rawValue:))
        audioViewMode = storedAudioMode ?? .icons
    }

    /// Restore persisted root folders and scan them. Call once when the UI appears.
    func restore() {
        let failures = rootStore.restore()
        if !failures.isEmpty {
            loadError = failures.first
        }
        rescanRoots()
    }

    var hasRootFolders: Bool { !rootStore.urls.isEmpty }

    // MARK: - Root folder management

    func addRootFolder() {
        guard rootStore.addFolder() != nil else { return }
        loadError = nil
        rescanRoots()
    }

    func removeRootFolder(id: MediaFolder.ID) {
        let url = URL(fileURLWithPath: id)
        rootStore.removeFolder(url)
        if selectedFolderID == id {
            selectedFolderID = nil
            setMediaItems([])
        }
        rescanRoots()
    }

    // MARK: - Scanning

    private func rescanRoots() {
        scanTask?.cancel()
        let urls = rootStore.urls
        scanTask = Task {
            var trees: [MediaFolder] = []
            do {
                for url in urls {
                    let tree = try await FolderScanner.buildTree(for: url)
                    trees.append(tree)
                }
            } catch is CancellationError {
                return
            } catch {
                loadError = "Some folders could not be read. Try removing and re-adding them."
            }

            guard !Task.isCancelled else { return }
            rootTrees = trees

            // Drop a selection that no longer exists in the refreshed tree.
            if let selection = selectedFolderID, !folderExists(withID: selection, in: trees) {
                selectedFolderID = nil
                setMediaItems([])
            }
        }
    }

    private func loadMediaForSelection() {
        mediaTask?.cancel()
        guard let id = selectedFolderID else {
            setMediaItems([])
            return
        }

        let url = URL(fileURLWithPath: id)
        isLoadingMedia = true
        mediaTask = Task {
            defer { isLoadingMedia = false }
            do {
                let items = try await FolderScanner.mediaItems(in: url)
                guard !Task.isCancelled else { return }
                setMediaItems(items)
            } catch is CancellationError {
                return
            } catch {
                setMediaItems([])
                loadError = "This folder could not be read."
            }
        }
    }

    /// Replace the current listing, rebuild the per-section splits, and drop any
    /// playback or viewer state that referred to the previous folder.
    private func setMediaItems(_ items: [MediaItem]) {
        mediaItems = items
        cardAspectRatio = Self.cardAspectRatio(for: items)
        playingVideoID = nil
        playingAudioID = nil
        viewerItemID = nil
        selectedItemIDs = []
        selectionAnchorID = nil
        focusedItemID = nil
        applySearchFilter()
    }

    /// Use the median image ratio when every image is landscape. Missing or
    /// invalid dimensions, square/portrait images, and video-only folders all
    /// deliberately fall back to square cards.
    nonisolated static func cardAspectRatio(for items: [MediaItem]) -> Double {
        let images = items.compactMap { item -> MediaItem? in
            switch item.type {
            case .image: item
            case .video, .audio: nil
            }
        }
        guard !images.isEmpty else { return 1 }

        var ratios: [Double] = []
        ratios.reserveCapacity(images.count)

        for image in images {
            guard let width = image.width,
                  let height = image.height,
                  width > height,
                  height > 0
            else {
                return 1
            }
            ratios.append(Double(width) / Double(height))
        }

        ratios.sort()
        let middle = ratios.count / 2
        if ratios.count.isMultiple(of: 2) {
            return (ratios[middle - 1] + ratios[middle]) / 2
        }
        return ratios[middle]
    }

    // MARK: - Search

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rebuild the visible sections and ensure no interaction state refers to an
    /// item hidden by the new query.
    private func applySearchFilter() {
        let query = normalizedSearchQuery
        let visibleItems = query.isEmpty
            ? mediaItems
            : mediaItems.filter { $0.name.localizedStandardContains(query) }

        visualItems = visibleItems.filter { $0.type == .image || $0.type == .video }
        audioItems = visibleItems.filter { $0.type == .audio }

        let visibleIDs = Set(visibleItems.map(\.id))
        selectedItemIDs.formIntersection(visibleIDs)

        if let playingVideoID, !visibleIDs.contains(playingVideoID) {
            self.playingVideoID = nil
        }
        if let playingAudioID, !visibleIDs.contains(playingAudioID) {
            self.playingAudioID = nil
        }
        if let viewerItemID, !visibleIDs.contains(viewerItemID) {
            self.viewerItemID = nil
        }

        if let focusedItemID, !visibleIDs.contains(focusedItemID) {
            self.focusedItemID = orderedItems.first {
                selectedItemIDs.contains($0.id)
            }?.id
        }
        if let selectionAnchorID, !visibleIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = focusedItemID
        }
    }

    // MARK: - Selection

    /// The items in visual order: the grid (images and videos) followed by the
    /// audio list. Selection and keyboard navigation walk this sequence so Up/Down
    /// can carry the cursor between the two sections.
    var orderedItems: [MediaItem] { visualItems + audioItems }

    /// Update the selection for a click on `item`.
    ///
    /// - `extend`: Shift-click — select the range from the anchor to `item`.
    /// - `toggle`: Command-click or Control-click — add or remove `item` without
    ///   disturbing the rest.
    /// - neither: a plain click that selects only `item`.
    func selectItem(_ item: MediaItem, toggle: Bool = false, extend: Bool = false) {
        if extend, let anchor = selectionAnchorID ?? focusedItemID {
            selectRange(from: anchor, to: item.id)
            focusedItemID = item.id
            return
        }

        if toggle {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
            focusedItemID = item.id
            selectionAnchorID = item.id
            return
        }

        selectedItemIDs = [item.id]
        focusedItemID = item.id
        selectionAnchorID = item.id
    }

    private func selectRange(from: MediaItem.ID, to: MediaItem.ID) {
        let ordered = orderedItems
        guard let a = ordered.firstIndex(where: { $0.id == from }),
              let b = ordered.firstIndex(where: { $0.id == to })
        else {
            selectedItemIDs = [to]
            return
        }
        let range = a <= b ? a...b : b...a
        selectedItemIDs = Set(ordered[range].map(\.id))
    }

    func selectAll() {
        selectedItemIDs = Set(orderedItems.map(\.id))
        if focusedItemID == nil { focusedItemID = orderedItems.first?.id }
    }

    func clearSelection() {
        selectedItemIDs = []
        selectionAnchorID = nil
        focusedItemID = nil
    }

    /// Move the keyboard cursor through `orderedItems`.
    ///
    /// Left/Right step by one; Up/Down step by a full grid row while in the visual
    /// grid and by one while in the single-column audio list. Movement clamps at
    /// either end rather than wrapping, matching Finder.
    func moveSelection(
        _ direction: MoveDirection,
        columns: Int,
        audioColumns: Int = 1,
        extending: Bool
    ) {
        let ordered = orderedItems
        guard !ordered.isEmpty else { return }

        let cols = max(1, columns)
        let audioCols = max(1, audioColumns)
        let visualCount = visualItems.count
        let currentIndex = focusedItemID
            .flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0
        let inAudio = currentIndex >= visualCount

        var target: Int
        switch direction {
        case .left: target = currentIndex - 1
        case .right: target = currentIndex + 1
        case .up: target = inAudio ? currentIndex - audioCols : currentIndex - cols
        case .down: target = inAudio ? currentIndex + audioCols : currentIndex + cols
        }
        target = min(max(target, 0), ordered.count - 1)

        let item = ordered[target]
        selectItem(item, extend: extending)
    }

    // MARK: - Preview / viewer playlist

    /// The set of items the viewer's Left/Right navigation walks. When two or more
    /// visual items are selected, browsing is confined to that subset; otherwise it
    /// spans every image and video in the folder.
    var viewerPlaylist: [MediaItem] {
        let selectedVisual = visualItems.filter { selectedItemIDs.contains($0.id) }
        return selectedVisual.count >= 2 ? selectedVisual : visualItems
    }

    /// Open the preview for the current selection. Uses the focused item when it is
    /// an image or video, otherwise the first selected visual item. Audio-only
    /// selections do nothing (audio is not previewable).
    func openPreview() {
        if let focusedItemID,
           let focused = orderedItems.first(where: { $0.id == focusedItemID }),
           focused.type != .audio {
            openViewer(focused)
            return
        }
        if let firstVisual = visualItems.first(where: { selectedItemIDs.contains($0.id) }) {
            openViewer(firstVisual)
        }
    }

    /// Select `item` and, if it is previewable, open it in the viewer. Used for
    /// double-click.
    func previewItem(_ item: MediaItem) {
        selectItem(item)
        if item.type != .audio {
            openViewer(item)
        }
    }

    /// Start or stop inline playback of the focused item. Videos toggle
    /// `playingVideoID`, audio toggles `playingAudioID`, images are ignored.
    func togglePlaybackOfFocusedItem() {
        guard let focusedItemID,
              let item = orderedItems.first(where: { $0.id == focusedItemID })
        else { return }

        switch item.type {
        case .video:
            playingVideoID = (playingVideoID == item.id) ? nil : item.id
        case .audio:
            playingAudioID = (playingAudioID == item.id) ? nil : item.id
        case .image:
            break
        }
    }

    // MARK: - Trash

    /// Move the selected items to the Trash, Finder-style: recoverable, not a
    /// permanent delete. Files that succeed are removed from the listing
    /// immediately; the focus moves to the nearest surviving neighbour.
    func moveSelectedItemsToTrash() {
        guard !selectedItemIDs.isEmpty else { return }

        let ordered = orderedItems
        let targets = ordered.filter { selectedItemIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        let firstDeletedIndex = ordered.firstIndex { selectedItemIDs.contains($0.id) } ?? 0

        var trashedIDs: Set<MediaItem.ID> = []
        var failed = false
        for item in targets {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                trashedIDs.insert(item.id)
            } catch {
                failed = true
            }
        }

        guard !trashedIDs.isEmpty else {
            loadError = "The selected items could not be moved to the Trash. If this folder was added before deletion was enabled, remove and re-add it to grant write access."
            return
        }

        if let playingVideoID, trashedIDs.contains(playingVideoID) { self.playingVideoID = nil }
        if let playingAudioID, trashedIDs.contains(playingAudioID) { self.playingAudioID = nil }
        if let viewerItemID, trashedIDs.contains(viewerItemID) { self.viewerItemID = nil }

        mediaItems.removeAll { trashedIDs.contains($0.id) }
        selectedItemIDs.subtract(trashedIDs)
        applySearchFilter()

        let newOrdered = orderedItems
        if newOrdered.isEmpty {
            focusedItemID = nil
            selectionAnchorID = nil
            selectedItemIDs = []
        } else {
            let idx = min(firstDeletedIndex, newOrdered.count - 1)
            let newFocus = newOrdered[idx]
            focusedItemID = newFocus.id
            selectionAnchorID = newFocus.id
            selectedItemIDs = [newFocus.id]
        }

        if failed {
            loadError = "Some items could not be moved to the Trash."
        }

        // A newly emptied folder should disappear from the smart sidebar.
        rescanRoots()
    }

    // MARK: - Full media viewer

    /// The item currently presented in the viewer, resolved from its id.
    var viewerItem: MediaItem? {
        guard let viewerItemID else { return nil }
        return visualItems.first { $0.id == viewerItemID }
    }

    func openViewer(_ item: MediaItem) {
        // The viewer creates its own player; releasing the inline ones keeps the
        // "one player at a time" invariant and stops audio playing underneath it.
        playingVideoID = nil
        playingAudioID = nil
        viewerItemID = item.id
        focusedItemID = item.id
    }

    func closeViewer() {
        viewerItemID = nil
    }

    func showPreviousInViewer() {
        stepViewer(by: -1)
    }

    func showNextInViewer() {
        stepViewer(by: 1)
    }

    /// Move the viewer selection through `viewerPlaylist`, stopping at either end
    /// rather than wrapping around.
    private func stepViewer(by offset: Int) {
        let playlist = viewerPlaylist
        guard let viewerItemID,
              let index = playlist.firstIndex(where: { $0.id == viewerItemID })
        else { return }

        let next = index + offset
        guard playlist.indices.contains(next) else { return }
        self.viewerItemID = playlist[next].id
    }

    var canShowPreviousInViewer: Bool { viewerNeighbourExists(offset: -1) }
    var canShowNextInViewer: Bool { viewerNeighbourExists(offset: 1) }

    private func viewerNeighbourExists(offset: Int) -> Bool {
        let playlist = viewerPlaylist
        guard let viewerItemID,
              let index = playlist.firstIndex(where: { $0.id == viewerItemID })
        else { return false }
        return playlist.indices.contains(index + offset)
    }

    // MARK: - Helpers

    private func folderExists(withID id: MediaFolder.ID, in folders: [MediaFolder]) -> Bool {
        for folder in folders {
            if folder.id == id { return true }
            if folderExists(withID: id, in: folder.children) { return true }
        }
        return false
    }
}

//
//  BrowserModel.swift
//  MediaBrowser
//

import Foundation
import Observation

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
            loadMediaForSelection()
        }
    }

    /// Media directly contained in the selected folder.
    private(set) var mediaItems: [MediaItem] = []

    /// `mediaItems` split by presentation: images and videos share the grid while
    /// audio gets full-width rows (spec section 8). These are stored rather than
    /// computed because a folder may hold thousands of items and views read them
    /// on every body evaluation.
    private(set) var visualItems: [MediaItem] = []
    private(set) var audioItems: [MediaItem] = []

    /// The one grid cell permitted to hold a live `AVPlayer`.
    ///
    /// Playing a video assigns this, which implicitly tears down whatever was
    /// playing before — the invariant "at most one inline player exists" is
    /// therefore enforced by the state itself rather than by cells coordinating
    /// with each other (spec section 12).
    var playingVideoID: MediaItem.ID?

    /// The item shown in the focused full-screen viewer, if any (spec section 16).
    private(set) var viewerItemID: MediaItem.ID?

    private(set) var isScanning = false
    private(set) var isLoadingMedia = false

    /// A user-facing message when folders cannot be restored or read. Cleared once
    /// the situation is resolved (spec section 24).
    var loadError: String?

    /// Number of columns in the image/video grid (1...4), persisted between
    /// launches (spec section 9).
    var gridColumns: Int {
        didSet {
            let clamped = min(max(gridColumns, 1), 4)
            if clamped != gridColumns {
                gridColumns = clamped
                return
            }
            UserDefaults.standard.set(gridColumns, forKey: Self.gridColumnsKey)
        }
    }

    private static let gridColumnsKey = "gridColumns"

    private let rootStore = RootFolderStore()
    private var scanTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init() {
        let storedColumns = UserDefaults.standard.integer(forKey: Self.gridColumnsKey)
        gridColumns = storedColumns == 0 ? 3 : min(max(storedColumns, 1), 4)
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
        visualItems = items.filter { $0.type == .image || $0.type == .video }
        audioItems = items.filter { $0.type == .audio }
        playingVideoID = nil
        viewerItemID = nil
    }

    // MARK: - Full media viewer

    /// The item currently presented in the viewer, resolved from its id.
    var viewerItem: MediaItem? {
        guard let viewerItemID else { return nil }
        return visualItems.first { $0.id == viewerItemID }
    }

    func openViewer(_ item: MediaItem) {
        // The viewer creates its own player; releasing the inline one keeps the
        // "one player at a time" invariant.
        playingVideoID = nil
        viewerItemID = item.id
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

    /// Move the viewer selection through `visualItems`, stopping at either end
    /// rather than wrapping around.
    private func stepViewer(by offset: Int) {
        guard let viewerItemID,
              let index = visualItems.firstIndex(where: { $0.id == viewerItemID })
        else { return }

        let next = index + offset
        guard visualItems.indices.contains(next) else { return }
        self.viewerItemID = visualItems[next].id
    }

    var canShowPreviousInViewer: Bool { viewerNeighbourExists(offset: -1) }
    var canShowNextInViewer: Bool { viewerNeighbourExists(offset: 1) }

    private func viewerNeighbourExists(offset: Int) -> Bool {
        guard let viewerItemID,
              let index = visualItems.firstIndex(where: { $0.id == viewerItemID })
        else { return false }
        return visualItems.indices.contains(index + offset)
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

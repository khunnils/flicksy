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
            mediaItems = []
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
                mediaItems = []
            }
        }
    }

    private func loadMediaForSelection() {
        mediaTask?.cancel()
        guard let id = selectedFolderID else {
            mediaItems = []
            return
        }

        let url = URL(fileURLWithPath: id)
        isLoadingMedia = true
        mediaTask = Task {
            defer { isLoadingMedia = false }
            do {
                let items = try await FolderScanner.mediaItems(in: url)
                guard !Task.isCancelled else { return }
                mediaItems = items
            } catch is CancellationError {
                return
            } catch {
                mediaItems = []
                loadError = "This folder could not be read."
            }
        }
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

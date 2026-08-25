//
//  BrowserModel.swift
//  MediaBrowser
//

import AppKit
import Foundation
import Observation

/// Grid navigation directions for keyboard selection movement.
enum MoveDirection {
    case left, right, up, down
}

/// A sidebar selection can be a real media folder or Flicksy's app-owned virtual
/// clipboard history.
enum BrowserSource: Hashable {
    case clipboard
    case standardFolder(StandardBrowserFolder)
    case folder(MediaFolder.ID)
}

/// The presentations available for audio media.
enum AudioViewMode: String, CaseIterable {
    case list
    case waveforms
}

/// The two library panes. Images and video share a visual grid; audio has its
/// own list/waveform view so the two are never mixed in one scrolling list.
enum MediaLibraryTab: String, CaseIterable, Identifiable {
    case visual
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visual: "Images & Video"
        case .audio: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .visual: "photo.on.rectangle"
        case .audio: "waveform"
        }
    }
}

/// Keys the listing can be ordered by. The same choice applies to both library
/// tabs (name, last updated, and so on).
enum MediaSortKey: String, CaseIterable, Identifiable {
    case name
    case modified
    case size
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        }
    }

    var ascendingLabel: String {
        switch self {
        case .name: "A to Z"
        case .modified: "Oldest First"
        case .size: "Smallest First"
        case .kind: "Ascending"
        }
    }

    var descendingLabel: String {
        switch self {
        case .name: "Z to A"
        case .modified: "Newest First"
        case .size: "Largest First"
        case .kind: "Descending"
        }
    }

    /// Conventional direction when the user first picks this key: names A–Z,
    /// dates newest first, sizes largest first.
    var defaultAscending: Bool {
        switch self {
        case .name, .kind: true
        case .modified, .size: false
        }
    }
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

    /// Selection is typed so the virtual clipboard never has to masquerade as a
    /// filesystem path.
    var selectedSource: BrowserSource? {
        didSet {
            guard selectedSource != oldValue else { return }
            searchQuery = ""
            isSearchPresented = false
            isSearchFieldFocused = false
            if selectedSource == .clipboard {
                libraryTab = .visual
            }
            loadMediaForSelection()
        }
    }

    var hasSelectedSource: Bool { selectedSource != nil }
    var isClipboardSelected: Bool { selectedSource == .clipboard }

    /// Media directly contained in the selected folder.
    private(set) var mediaItems: [MediaItem] = []

    /// The current search text. Filtering is cheap filename matching over the
    /// already-loaded folder contents, so results update on every keystroke.
    var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            rebuildVisibleItems()
        }
    }

    /// Drives programmatic activation of the native toolbar search field.
    var isSearchPresented = false

    /// Mirrored from the search field's focus state so browser-level commands do
    /// not consume text-editing shortcuts while the user is typing.
    var isSearchFieldFocused = false

    var hasActiveSearch: Bool { !normalizedSearchQuery.isEmpty }

    /// Audio defaults to a metadata-rich list; a user's explicit choice is
    /// retained between launches.
    var audioViewMode: AudioViewMode {
        didSet {
            UserDefaults.standard.set(audioViewMode.rawValue, forKey: Self.audioViewModeKey)
        }
    }

    /// Which library pane is showing. Persisted so a creator who lives in Audio
    /// does not keep getting bounced back to stills.
    var libraryTab: MediaLibraryTab = .visual {
        didSet {
            guard libraryTab != oldValue else { return }
            UserDefaults.standard.set(libraryTab.rawValue, forKey: Self.libraryTabKey)
            isolateCurrentTab()
        }
    }

    func toggleLibraryTab() {
        guard !isClipboardSelected else {
            libraryTab = .visual
            return
        }
        switch libraryTab {
        case .visual:
            libraryTab = .audio
        case .audio:
            libraryTab = .visual
        }
    }

    /// Shared sort, applied to whichever tab is visible.
    var sortKey: MediaSortKey = .name {
        didSet {
            guard sortKey != oldValue else { return }
            UserDefaults.standard.set(sortKey.rawValue, forKey: Self.sortKeyKey)
            sortAscending = sortKey.defaultAscending
            rebuildVisibleItems()
        }
    }

    var sortAscending: Bool = true {
        didSet {
            guard sortAscending != oldValue else { return }
            UserDefaults.standard.set(sortAscending, forKey: Self.sortAscendingKey)
            rebuildVisibleItems()
        }
    }

    /// `mediaItems` filtered by `searchQuery`, split by type, and ordered by
    /// `sortKey`. Images and videos share the visual tab; audio has its own.
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
    private(set) var clipboardItemCount = 0

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
    private static let libraryTabKey = "libraryTab"
    private static let sortKeyKey = "sortKey"
    private static let sortAscendingKey = "sortAscending"

    private let rootStore = RootFolderStore()
    private let standardFolderStore = StandardFolderStore()
    private let clipboardStore = ClipboardHistoryStore()
    private var scanTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var fileSystemMonitor: FileSystemMonitor?
    private var monitorRefreshTask: Task<Void, Never>?
    private var activeScanID: UUID?
    private var activeMediaLoadID: UUID?
    private var clipboardMonitorTask: Task<Void, Never>?
    private var lastPasteboardChangeCount: Int?

    // MARK: - Lifecycle

    init() {
        PersistentMediaCache.scheduleMaintenance()

        let storedSize = UserDefaults.standard.object(forKey: Self.thumbnailSizeKey) as? Double
        thumbnailSize = storedSize.map(Self.clampedThumbnailSize) ?? Self.defaultThumbnailSize

        let storedAudioMode = UserDefaults.standard.string(forKey: Self.audioViewModeKey)
            .flatMap(AudioViewMode.init(rawValue:))
        audioViewMode = storedAudioMode ?? .list

        let storedTab = UserDefaults.standard.string(forKey: Self.libraryTabKey)
            .flatMap(MediaLibraryTab.init(rawValue:))
        libraryTab = storedTab ?? .visual

        let storedSort = UserDefaults.standard.string(forKey: Self.sortKeyKey)
            .flatMap(MediaSortKey.init(rawValue:))
        sortKey = storedSort ?? .name

        if UserDefaults.standard.object(forKey: Self.sortAscendingKey) == nil {
            sortAscending = (storedSort ?? .name).defaultAscending
        } else {
            sortAscending = UserDefaults.standard.bool(forKey: Self.sortAscendingKey)
        }
    }

    /// Restore persisted root folders and scan them. Call once when the UI appears.
    func restore() {
        standardFolderStore.restore()
        let failures = rootStore.restore()
        if !failures.isEmpty {
            loadError = failures.first
        }
        restartFilesystemMonitoring()
        rescanRoots()
        startClipboardMonitoring()
    }

    var hasRootFolders: Bool { !rootStore.urls.isEmpty }

    // MARK: - Root folder management

    func addRootFolder() {
        guard rootStore.addFolder() != nil else { return }
        loadError = nil
        restartFilesystemMonitoring()
        rescanRoots()
    }

    func removeRootFolder(id: MediaFolder.ID) {
        let url = URL(fileURLWithPath: id)
        rootStore.removeFolder(url)
        if selectedSource == .folder(id) {
            selectedSource = nil
            setMediaItems([])
        }
        restartFilesystemMonitoring()
        rescanRoots()
    }

    // MARK: - Finder / pasteboard

    /// Items a context-menu or keyboard command should act on. Right-clicking an
    /// unselected item acts on that item alone (and selects it); right-clicking
    /// inside a selection acts on every selected item.
    func itemsForAction(clicked item: MediaItem?) -> [MediaItem] {
        if let item {
            if selectedItemIDs.contains(item.id) {
                return orderedItems.filter { selectedItemIDs.contains($0.id) }
            }
            selectItem(item)
            return [item]
        }
        if let viewerItem {
            return [viewerItem]
        }
        return orderedItems.filter { selectedItemIDs.contains($0.id) }
    }

    func openFromContextMenu(_ item: MediaItem) {
        selectItem(item)
        switch item.type {
        case .image, .video:
            openViewer(item)
        case .audio:
            playingAudioID = item.id
        }
    }

    func revealInFinder(clicked item: MediaItem? = nil) {
        let urls = itemsForAction(clicked: item).map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copyPath(clicked item: MediaItem? = nil) {
        let urls = itemsForAction(clicked: item).map(\.url)
        guard !urls.isEmpty else { return }
        let string = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Copy the selected files themselves so they can be pasted into Finder.
    func copySelectedFiles(clicked item: MediaItem? = nil) {
        let urls = itemsForAction(clicked: item).map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
    }

    /// URLs to put on the pasteboard for a drag starting at `item`.
    func prepareDrag(from item: MediaItem) -> [URL] {
        if selectedItemIDs.contains(item.id) {
            return orderedItems.filter { selectedItemIDs.contains($0.id) }.map(\.url)
        }
        selectItem(item)
        return [item.url]
    }

    // MARK: - Clipboard history

    func clearClipboardHistory() {
        Task {
            do {
                let items = try await clipboardStore.clear()
                clipboardItemCount = 0
                if isClipboardSelected {
                    setMediaItems(items)
                }
            } catch {
                loadError = "Clipboard history could not be cleared."
            }
        }
    }

    private func startClipboardMonitoring() {
        guard clipboardMonitorTask == nil else { return }
        clipboardMonitorTask = Task { [weak self] in
            guard let self else { return }

            let stored = await clipboardStore.items()
            clipboardItemCount = stored.count
            if isClipboardSelected {
                setMediaItems(stored)
            }

            while !Task.isCancelled {
                await captureClipboardIfChanged()
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    private func captureClipboardIfChanged() async {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = changeCount

        let candidates = ClipboardPasteboardReader.candidates(from: pasteboard)
        guard !candidates.isEmpty else { return }

        do {
            let items = try await clipboardStore.importImages(candidates)
            clipboardItemCount = items.count
            if isClipboardSelected {
                setMediaItems(items)
            }
        } catch {
            // Pasteboard owners can disappear while providing lazy data. Ignore
            // that transient change; the next copy operation gets another pass.
        }
    }

    // MARK: - Scanning

    private func restartFilesystemMonitoring() {
        fileSystemMonitor = FileSystemMonitor(
            urls: rootStore.urls + standardFolderStore.monitoredURLs
        ) { [weak self] in
            self?.filesystemDidChange()
        }
    }

    /// Editors often emit several rename/write events for one save. Coalesce the
    /// burst so large roots are scanned once, and cancel an obsolete pending pass
    /// if more changes arrive before it starts.
    private func filesystemDidChange() {
        monitorRefreshTask?.cancel()
        monitorRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            rescanRoots()
            if case .folder = selectedSource {
                loadMediaForSelection()
            } else if case .standardFolder = selectedSource {
                loadMediaForSelection()
            }
        }
    }

    private func rescanRoots() {
        scanTask?.cancel()
        let urls = rootStore.urls
        let scanID = UUID()
        activeScanID = scanID
        isScanning = true
        scanTask = Task {
            defer {
                if activeScanID == scanID {
                    activeScanID = nil
                    isScanning = false
                }
            }
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
            if case .folder(let selection) = selectedSource,
               !folderExists(withID: selection, in: trees) {
                selectedSource = nil
                setMediaItems([])
            }
        }
    }

    private func loadMediaForSelection() {
        mediaTask?.cancel()
        activeMediaLoadID = nil
        guard let source = selectedSource else {
            isLoadingMedia = false
            setMediaItems([])
            return
        }

        let loadID = UUID()
        activeMediaLoadID = loadID
        isLoadingMedia = true
        mediaTask = Task {
            defer {
                if activeMediaLoadID == loadID {
                    activeMediaLoadID = nil
                    isLoadingMedia = false
                }
            }
            do {
                let items: [MediaItem]
                switch source {
                case .clipboard:
                    items = await clipboardStore.items()
                    clipboardItemCount = items.count
                case .standardFolder(let folder):
                    guard let url = urlForStandardFolder(folder) else {
                        setMediaItems([])
                        loadError = "Access to \(folder.title) was not granted."
                        return
                    }
                    restartFilesystemMonitoring()
                    items = try await FolderScanner.mediaItems(in: url)
                case .folder(let id):
                    items = try await FolderScanner.mediaItems(
                        in: URL(fileURLWithPath: id)
                    )
                }
                guard !Task.isCancelled else { return }
                setMediaItems(items)
            } catch is CancellationError {
                return
            } catch {
                setMediaItems([])
                loadError = source == .clipboard
                    ? "Clipboard history could not be loaded."
                    : "This folder could not be read."
            }
        }
    }

    /// Reuse an existing user-added root when it points at the same standard
    /// location, avoiding a second permission prompt for Desktop.
    private func urlForStandardFolder(_ folder: StandardBrowserFolder) -> URL? {
        // Downloads uses its dedicated sandbox entitlement. Never allow an old
        // bookmark or user-added root to override that stable system URL.
        if folder == .downloads {
            return standardFolderStore.url(for: .downloads)
        }

        if let standardURL = folder.url?.standardizedFileURL,
           let authorizedRoot = rootStore.urls.first(where: {
               $0.standardizedFileURL == standardURL
           }) {
            return authorizedRoot
        }
        return standardFolderStore.url(for: folder)
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
        rebuildVisibleItems()
        preferPopulatedTab()
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

    /// Rebuild the visible tab listings: search filter, type split, then the
    /// shared sort. Drops interaction state that pointed at items no longer shown.
    private func rebuildVisibleItems() {
        let query = normalizedSearchQuery
        let visibleItems = query.isEmpty
            ? mediaItems
            : mediaItems.filter { $0.name.localizedStandardContains(query) }

        visualItems = sortedItems(visibleItems.filter { $0.type == .image || $0.type == .video })
        audioItems = sortedItems(visibleItems.filter { $0.type == .audio })

        isolateCurrentTab()
    }

    /// Keep selection, playback and the viewer inside the active tab, and drop
    /// anything that refers to a file the current listing no longer contains.
    private func isolateCurrentTab() {
        let visibleIDs = Set(orderedItems.map(\.id))
        selectedItemIDs.formIntersection(visibleIDs)

        if libraryTab != .visual {
            playingVideoID = nil
            viewerItemID = nil
        } else if let playingVideoID, !visibleIDs.contains(playingVideoID) {
            self.playingVideoID = nil
        }

        if libraryTab != .audio {
            playingAudioID = nil
        } else if let playingAudioID, !visibleIDs.contains(playingAudioID) {
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

    /// If the restored tab is empty for this folder but the other is not, show
    /// the tab that actually has files.
    private func preferPopulatedTab() {
        let hasVisual = mediaItems.contains { $0.type == .image || $0.type == .video }
        let hasAudio = mediaItems.contains { $0.type == .audio }
        switch libraryTab {
        case .visual where !hasVisual && hasAudio:
            libraryTab = .audio
        case .audio where !hasAudio && hasVisual:
            libraryTab = .visual
        default:
            break
        }
    }

    private func sortedItems(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { lhs, rhs in
            if let result = compare(lhs, rhs, by: sortKey), result != .orderedSame {
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
            let name = lhs.name.localizedStandardCompare(rhs.name)
            if name != .orderedSame {
                return name == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    /// Primary comparison for `sortKey`. Returns `nil` when both values are
    /// missing so the caller can fall through to a name tie-breaker. Missing
    /// dates/sizes always sort last, regardless of direction.
    private func compare(_ lhs: MediaItem, _ rhs: MediaItem, by key: MediaSortKey) -> ComparisonResult? {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .modified:
            return compareOptional(lhs.modifiedAt, rhs.modifiedAt)
        case .size:
            return compareOptional(lhs.fileSize, rhs.fileSize)
        case .kind:
            return compareOptional(Optional(kindRank(lhs.type)), Optional(kindRank(rhs.type)))
        }
    }

    private func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case (nil, _):
            return sortAscending ? .orderedDescending : .orderedAscending
        case (_, nil):
            return sortAscending ? .orderedAscending : .orderedDescending
        case (let a?, let b?):
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        }
    }

    private func kindRank(_ type: MediaType) -> Int {
        switch type {
        case .image: 0
        case .video: 1
        case .audio: 2
        }
    }

    // MARK: - Selection

    /// Items in the active tab, in the current sort order. Selection, keyboard
    /// navigation and Select All walk this list so they never cross into the
    /// hidden tab.
    var orderedItems: [MediaItem] {
        switch libraryTab {
        case .visual: visualItems
        case .audio: audioItems
        }
    }

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

    /// Move the keyboard cursor through the active tab.
    ///
    /// Left/Right step by one; Up/Down step by a full row. Movement clamps at
    /// either end rather than wrapping, matching Finder.
    func moveSelection(_ direction: MoveDirection, columns: Int, extending: Bool) {
        let ordered = orderedItems
        guard !ordered.isEmpty else { return }

        let cols = max(1, columns)
        let currentIndex = focusedItemID
            .flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0

        var target: Int
        switch direction {
        case .left: target = currentIndex - 1
        case .right: target = currentIndex + 1
        case .up: target = currentIndex - cols
        case .down: target = currentIndex + cols
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

        let wasClipboard = isClipboardSelected
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
        rebuildVisibleItems()

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

        if wasClipboard {
            let trashedURLs = targets
                .filter { trashedIDs.contains($0.id) }
                .map(\.url)
            Task {
                if let items = try? await clipboardStore.removeReferences(to: trashedURLs) {
                    clipboardItemCount = items.count
                }
            }
        } else {
            // A newly emptied folder should disappear from the smart sidebar.
            rescanRoots()
        }
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

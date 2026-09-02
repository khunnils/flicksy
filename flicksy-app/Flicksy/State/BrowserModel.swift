//
//  BrowserModel.swift
//  MediaBrowser
//

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Grid navigation directions for keyboard selection movement.
enum MoveDirection {
    case left, right, up, down
}

/// A pending tag rename that collided with an existing tag. Kept until the user
/// confirms or cancels the merge so the two are only combined on purpose.
struct PendingTagMerge: Identifiable {
    let id = UUID()
    let tag: LibraryTag
    let name: String
    let color: LibraryTagColor
}

/// MP3s opened in the Edit Meta Tags sheet. `id` is stable for the sheet while
/// those files stay selected.
struct AudioTagsEditRequest: Identifiable, Equatable {
    let items: [MediaItem]
    var id: String { items.map(\.id).joined(separator: "\u{1e}") }
}

/// A sidebar selection can be a real media folder or Flicksy's app-owned virtual
/// clipboard history.
enum BrowserSource: Hashable, Sendable {
    case favorites
    case tag(UUID)
    case collection(UUID)
    case clipboard
    case standardFolder(StandardBrowserFolder)
    case folder(MediaFolder.ID)
}

/// Cache reads and live scan batches race through one stream. Fast local folders
/// usually produce a live batch first; slower/network folders can paint from the
/// cache without delaying reconciliation.
private enum FolderLoadEvent: Sendable {
    case cached([MediaItem])
    case liveBatch([MediaItem])
    case failed
}

/// The library panes. All media shares a metadata list, images and video use a
/// visual grid, and audio uses a metadata list with a bottom waveform inspector.
enum MediaLibraryTab: String, CaseIterable, Identifiable {
    case all
    case visual
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .visual: "Images & Video"
        case .audio: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .visual: "photo.on.rectangle"
        case .audio: "waveform"
        }
    }
}

/// Keys the listing can be ordered by. The same choice applies to both library
/// tabs (name, last updated, and so on).
enum MediaSortKey: String, CaseIterable, Identifiable {
    case manual
    case name
    case kind
    case added
    case modified
    case duration
    case dimensions
    case bitRate
    case sampleRate
    case channels
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual Order"
        case .name: "Name"
        case .kind: "Kind"
        case .added: "Date Added"
        case .modified: "Date Modified"
        case .duration: "Duration"
        case .dimensions: "Dimensions"
        case .bitRate: "Bit Rate"
        case .sampleRate: "Sample Rate"
        case .channels: "Channels"
        case .size: "Size"
        }
    }

    var ascendingLabel: String {
        switch self {
        case .manual: "First to Last"
        case .name: "A to Z"
        case .kind: "Ascending"
        case .added, .modified: "Oldest First"
        case .duration: "Shortest First"
        case .dimensions: "Smallest First"
        case .bitRate, .sampleRate: "Lowest First"
        case .channels: "Fewest First"
        case .size: "Smallest First"
        }
    }

    var descendingLabel: String {
        switch self {
        case .manual: "Last to First"
        case .name: "Z to A"
        case .kind: "Descending"
        case .added, .modified: "Newest First"
        case .duration: "Longest First"
        case .dimensions: "Largest First"
        case .bitRate, .sampleRate: "Highest First"
        case .channels: "Most First"
        case .size: "Largest First"
        }
    }

    /// Conventional direction when the user first picks this key: names A–Z,
    /// dates newest first, sizes largest first.
    var defaultAscending: Bool {
        switch self {
        case .manual, .name, .kind, .channels: true
        case .added, .modified, .duration, .dimensions, .bitRate, .sampleRate, .size: false
        }
    }

    /// These values are filled in after the folder scan, as list rows load
    /// `AVAsset` metadata. Re-sorting waits until that data exists.
    var usesDeferredMetadata: Bool {
        switch self {
        case .duration, .dimensions, .bitRate, .sampleRate, .channels: true
        default: false
        }
    }
}

/// Inspector transport jumps and skips.
enum AudioSeekKind {
    case start
    case end
    case rewind
    case forward
}

/// Fine-grained selection state used by an individual media cell.
///
/// Keeping this separate from the complete selection set means changing one
/// selected item only invalidates the rows whose highlight actually changed.
/// Large lazy lists otherwise have to rebuild every row to pass a new Set down.
@Observable
@MainActor
final class MediaItemSelectionState {
    var isSelected: Bool

    init(isSelected: Bool) {
        self.isSelected = isSelected
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
            if case .collection = selectedSource {
                if sortKey != .manual { sortKey = .manual }
            } else if sortKey == .manual {
                sortKey = .name
            }
            loadMediaForSelection()
        }
    }

    var hasSelectedSource: Bool { selectedSource != nil }
    var isClipboardSelected: Bool { selectedSource == .clipboard }
    var selectedCollectionID: UUID? {
        guard case .collection(let id) = selectedSource else { return nil }
        return id
    }
    var isCollectionSelected: Bool { selectedCollectionID != nil }
    var isLibrarySourceSelected: Bool {
        switch selectedSource {
        case .favorites, .tag, .collection: true
        default: false
        }
    }

    /// Media directly contained in the selected folder.
    private(set) var mediaItems: [MediaItem] = []
    private(set) var tags: [LibraryTag] = []
    private(set) var collections: [MediaCollection] = []
    private(set) var missingCollectionItems: [MissingCollectionItem] = []
    private(set) var isIndexingLibrary = false

    /// Snapshots backing open Get Info windows. Keeping these independent from
    /// the current folder lets an inspector remain useful while browsing away.
    private var infoItems: [MediaItem.ID: MediaItem] = [:]

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

    /// Drives the window-level Jump to picker opened by Command-J.
    var isQuickGotoPresented = false

    /// Keeps native pasteboard shortcuts available while the destination query
    /// owns keyboard focus.
    var isQuickGotoFieldFocused = false

    /// Drives the window-level command palette opened by Command-K.
    var isCommandPalettePresented = false
    var isCommandPaletteFieldFocused = false
    private(set) var commandPaletteSearchIndex: CommandPaletteSearchIndex?
    private(set) var isLoadingCommandPaletteIndex = false

    /// The MP3s whose meta-tag editor sheet is open. Also used so Command-C copies
    /// field text instead of the selected files while the dialog is up.
    var editAudioTagsRequest: AudioTagsEditRequest?

    /// Drives the window-level keyboard shortcuts helper opened by Command-/.
    var isShortcutsHelpPresented = false

    /// Drives the first-run welcome sheet and the Help-menu replay of it.
    var isWelcomePresented = false

    var isTextFieldFocused: Bool {
        isSearchFieldFocused
            || isQuickGotoFieldFocused
            || isCommandPaletteFieldFocused
            || editAudioTagsRequest != nil
    }

    func presentQuickGoto() {
        isSearchPresented = false
        isShortcutsHelpPresented = false
        dismissCommandPalette()
        isQuickGotoPresented = true
    }

    func toggleCommandPalette() {
        if isCommandPalettePresented {
            dismissCommandPalette()
        } else {
            presentCommandPalette()
        }
    }

    func presentCommandPalette() {
        isSearchPresented = false
        isQuickGotoPresented = false
        isQuickGotoFieldFocused = false
        isShortcutsHelpPresented = false
        isCommandPalettePresented = true
        loadCommandPaletteIndexIfNeeded()
    }

    func dismissCommandPalette() {
        isCommandPalettePresented = false
        isCommandPaletteFieldFocused = false
    }

    func presentShortcutsHelp() {
        if isShortcutsHelpPresented {
            isShortcutsHelpPresented = false
            return
        }
        isSearchPresented = false
        isQuickGotoPresented = false
        isQuickGotoFieldFocused = false
        dismissCommandPalette()
        isShortcutsHelpPresented = true
    }

    func presentWelcome() {
        isSearchPresented = false
        isSearchFieldFocused = false
        isQuickGotoPresented = false
        isQuickGotoFieldFocused = false
        isShortcutsHelpPresented = false
        isOrganizePresented = false
        dismissCommandPalette()
        isWelcomePresented = true
    }

    func completeWelcome() {
        onboardingStore.markCompleted()
        isWelcomePresented = false
    }

    func go(to source: BrowserSource) {
        isQuickGotoPresented = false
        isQuickGotoFieldFocused = false
        isShortcutsHelpPresented = false
        dismissCommandPalette()
        selectedSource = source
    }

    var hasActiveSearch: Bool { !normalizedSearchQuery.isEmpty }

    /// Which library pane is showing. Persisted so a creator who lives in Audio
    /// does not keep getting bounced back to stills.
    var libraryTab: MediaLibraryTab = .visual {
        didSet {
            guard libraryTab != oldValue else { return }
            UserDefaults.standard.set(libraryTab.rawValue, forKey: Self.libraryTabKey)
            isolateCurrentTab()
        }
    }

    func selectLibraryTab(_ tab: MediaLibraryTab) {
        if isClipboardSelected, tab == .audio { return }
        libraryTab = tab
    }

    /// Incremented when the inspector should jump or skip.
    private(set) var audioSeekRequestID = 0
    private(set) var audioSeekKind: AudioSeekKind = .start

    var canControlInspectorAudio: Bool {
        selectedAudioItem != nil || playingAudioID != nil
    }

    func requestAudioSeek(_ kind: AudioSeekKind) {
        guard canControlInspectorAudio else { return }
        audioSeekKind = kind
        audioSeekRequestID += 1
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

    /// Clicking a list column sorts by it, or reverses the current direction.
    func sortByColumn(_ key: MediaSortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
        }
    }

    /// `mediaItems` filtered by `searchQuery`, split by type, and ordered by
    /// `sortKey`. The All tab retains the complete filtered listing.
    private(set) var allItems: [MediaItem] = []
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
            if playingAudioID != oldValue {
                isAudioPlaying = playingAudioID != nil
            }
            if playingAudioID != nil { playingVideoID = nil }
        }
    }

    /// True while the audio inspector (or All-tab row) is actually outputting
    /// sound. Distinct from `playingAudioID`, which only claims the slot.
    var isAudioPlaying = false

    /// Session transport: loop the inspector's current in/out range. Not saved.
    var isAudioLooping = false

    /// The single selected audio item, when the inspector should be shown.
    var selectedAudioItem: MediaItem? {
        guard selectedItemIDs.count == 1,
              let id = selectedItemIDs.first,
              let item = orderedItemByID[id],
              item.type == .audio
        else { return nil }
        return item
    }

    private(set) var isApplyingAudioTrim = false

    /// The item shown in the focused full-screen viewer, if any (spec section 16).
    private(set) var viewerItemID: MediaItem.ID?

    /// Session-only image comparison state. `compareItemIDs` keeps every
    /// participating thumbnail while `compareSlotItemIDs` is the visible subset.
    private(set) var isComparingImages = false
    private(set) var compareLayout: MediaCompareLayout = .twoByOne
    private(set) var compareItemIDs: [MediaItem.ID] = []
    private(set) var compareSlotItemIDs: [MediaItem.ID] = []
    private var compareReturnItemID: MediaItem.ID?

    /// Items the user has selected in the browser. Selection is independent of
    /// playback and viewer state: clicking selects (Finder-style) rather than
    /// opening, so the user can act on one or many items at once.
    var selectedItemIDs: Set<MediaItem.ID> = [] {
        didSet {
            selectionSnapshot = selectedItemIDs
            for id in oldValue.symmetricDifference(selectedItemIDs) {
                selectionStateByID[id]?.isSelected = selectedItemIDs.contains(id)
            }
            if isComparingImages {
                reconcileImageComparison()
            }
        }
    }

    /// The anchor for Shift-click / Shift-arrow range selection.
    var selectionAnchorID: MediaItem.ID?

    /// The keyboard cursor: the last item touched by a click or arrow move. Drives
    /// arrow navigation, Space preview and Enter playback.
    var focusedItemID: MediaItem.ID?

    private(set) var isScanning = false
    private(set) var isLoadingMedia = false
    private(set) var clipboardItemCount = 0
    private(set) var pasteboardContainsFileURLs = false
    var confirmsClearingClipboard = false

    /// A user-facing message when folders cannot be restored or read. Cleared once
    /// the situation is resolved (spec section 24).
    var loadError: String?

    /// A user-facing message for organization actions (tags, favorites,
    /// collections). Kept separate from `loadError` so a rejected drop does not
    /// offer to add a root folder, which would be the wrong remedy.
    var organizationError: String?

    /// Drives the toolbar Organize popover so it can also be opened with the
    /// keyboard (Command-T).
    var isOrganizePresented = false

    /// Organization editor shared by every command surface.
    var organizationEditorRequest: OrganizationEditorRequest?

    /// Shared rename prompt used by contextual menus and the command palette.
    var renameItemRequest: MediaItem?
    var renameProposedName = ""

    /// A rename that collided with an existing tag, awaiting the user's explicit
    /// confirmation to merge the two tags.
    var pendingTagMerge: PendingTagMerge?

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

    /// Zoom for the still image currently open in the full-window viewer. It is
    /// relative to fit-to-window, so 1 always means Fit. ZoomableImage supplies
    /// the geometry-dependent limits when its container changes.
    private(set) var viewerImageZoom: Double = 1
    private(set) var viewerImageMinimumZoom: Double = 1
    private(set) var viewerImageMaximumZoom: Double = 8
    private(set) var viewerImageActualSizeZoom: Double = 1

    static let viewerImageZoomFactor: Double = 1.25

    /// Crop session for the still open in the viewer. The guide is stored in
    /// normalized oriented-image coordinates (origin top-left, 0…1).
    private(set) var isCropping = false
    private(set) var isApplyingCrop = false
    var cropAspect: CropAspectRatio = .free
    var cropNormalizedRect = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
    /// Pixel size of the oriented still used to resolve aspect locks.
    private(set) var cropImageSize: CGSize = .zero

    static func clampedThumbnailSize(_ size: Double) -> Double {
        min(max(size, minThumbnailSize), maxThumbnailSize)
    }

    func zoomIn() {
        thumbnailSize = Self.clampedThumbnailSize(thumbnailSize + Self.thumbnailSizeStep)
    }

    func zoomOut() {
        thumbnailSize = Self.clampedThumbnailSize(thumbnailSize - Self.thumbnailSizeStep)
    }

    var isViewingImage: Bool { viewerItem?.type == .image }
    var canZoomViewerImageIn: Bool { !isCropping && viewerImageZoom < viewerImageMaximumZoom - 0.001 }
    var canZoomViewerImageOut: Bool { !isCropping && viewerImageZoom > viewerImageMinimumZoom + 0.001 }
    var isViewerImageFit: Bool { abs(viewerImageZoom - 1) < 0.04 }

    func configureViewerImageZoom(fitScale: CGFloat) {
        guard fitScale > 0 else { return }
        let actual = 1 / Double(fitScale)
        viewerImageActualSizeZoom = actual
        viewerImageMinimumZoom = min(1, actual)
        viewerImageMaximumZoom = max(8, actual * 4)
        setViewerImageZoom(viewerImageZoom)
    }

    func setViewerImageZoom(_ zoom: Double) {
        guard !isCropping else {
            viewerImageZoom = 1
            return
        }
        viewerImageZoom = min(max(zoom, viewerImageMinimumZoom), viewerImageMaximumZoom)
        if viewerImageZoom <= 1.02 && viewerImageMinimumZoom >= 0.98 {
            viewerImageZoom = 1
        }
    }

    func zoomViewerImageIn() {
        setViewerImageZoom(viewerImageZoom * Self.viewerImageZoomFactor)
    }

    func zoomViewerImageOut() {
        setViewerImageZoom(viewerImageZoom / Self.viewerImageZoomFactor)
    }

    func toggleViewerImageFitAndActualSize() {
        guard !isCropping else { return }
        setViewerImageZoom(isViewerImageFit ? viewerImageActualSizeZoom : 1)
    }

    private func resetViewerImageZoom() {
        viewerImageZoom = 1
        viewerImageMinimumZoom = 1
        viewerImageMaximumZoom = 8
        viewerImageActualSizeZoom = 1
    }

    func beginCrop() {
        guard isViewingImage, !isCropping else { return }
        setViewerImageZoom(1)
        cropAspect = .free
        if cropImageSize.width > 0, cropImageSize.height > 0 {
            cropNormalizedRect = ImageCropOverlay.largestNormalizedRect(
                aspect: .free,
                imageSize: cropImageSize
            )
        } else {
            cropNormalizedRect = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
        }
        isCropping = true
    }

    func cancelCrop() {
        guard isCropping, !isApplyingCrop else { return }
        isCropping = false
        cropAspect = .free
    }

    func setCropAspect(_ aspect: CropAspectRatio) {
        guard isCropping else { return }
        cropAspect = aspect
        // Overlay reacts to aspect changes and recenters the guide.
    }

    func updateCropImageSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        cropImageSize = size
        if isCropping,
           cropNormalizedRect.width < 0.05 || cropNormalizedRect.height < 0.05 {
            cropNormalizedRect = ImageCropOverlay.largestNormalizedRect(
                aspect: cropAspect,
                imageSize: size
            )
        }
    }

    func applyCrop() {
        guard isCropping, !isApplyingCrop, let item = viewerItem, item.type == .image else { return }
        let url = item.url
        let rect = cropNormalizedRect
        isApplyingCrop = true
        Task {
            defer { isApplyingCrop = false }
            do {
                let pixelSize = try await Task.detached(priority: .userInitiated) {
                    try ImageCropper.crop(url: url, normalizedRect: rect)
                }.value
                noteRewrittenFile(at: url, pixelSize: pixelSize)
                isCropping = false
                cropAspect = .free
                resetViewerImageZoom()
                if isLibrarySourceSelected {
                    await reconcileLibrary(roots: rootStore.urls)
                } else {
                    refreshAfterFileMutation()
                }
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    func rotateViewerImageLeft() {
        transformViewerImage(.rotateLeft)
    }

    func rotateViewerImageRight() {
        transformViewerImage(.rotateRight)
    }

    func flipViewerImageHorizontal() {
        transformViewerImage(.flipHorizontal)
    }

    func flipViewerImageVertical() {
        transformViewerImage(.flipVertical)
    }

    private func transformViewerImage(_ operation: ImageCropper.Transform) {
        guard !isCropping, !isApplyingCrop,
              let item = viewerItem, item.type == .image
        else { return }

        let url = item.url
        isApplyingCrop = true
        Task {
            defer { isApplyingCrop = false }
            do {
                let pixelSize = try await Task.detached(priority: .userInitiated) {
                    try ImageCropper.transform(url: url, operation: operation)
                }.value
                noteRewrittenFile(at: url, pixelSize: pixelSize)
                resetViewerImageZoom()
                if isLibrarySourceSelected {
                    await reconcileLibrary(roots: rootStore.urls)
                } else {
                    refreshAfterFileMutation()
                }
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    /// Overwrite the selected audio file with the inspector's in/out range.
    func trimSelectedAudio(start: TimeInterval, end: TimeInterval) {
        guard !isApplyingAudioTrim, let item = selectedAudioItem else { return }
        let url = item.url
        isApplyingAudioTrim = true
        playingAudioID = nil
        isAudioPlaying = false
        Task {
            defer { isApplyingAudioTrim = false }
            do {
                let duration = try await AudioTrimmer.trim(url: url, start: start, end: end)
                noteRewrittenFile(at: url, duration: duration)
                if isLibrarySourceSelected {
                    await reconcileLibrary(roots: rootStore.urls)
                } else {
                    refreshAfterFileMutation()
                }
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    /// Write Apple Music Details tags and refresh listings. When `fields` is set,
    /// only those fields are copied onto each file’s existing tags.
    func saveAudioTags(
        _ tags: AudioTags,
        applying fields: Set<AudioTagField>? = nil,
        to items: [MediaItem]
    ) async throws {
        if let playing = playingAudioID, items.contains(where: { $0.id == playing }) {
            playingAudioID = nil
            isAudioPlaying = false
        }
        for item in items {
            let next: AudioTags
            if let fields {
                let current = await AudioTagService.load(from: item.url)
                next = current.applying(tags, fields: fields)
            } else {
                next = tags
            }
            try await AudioTagService.write(next, to: item.url)
            noteRewrittenFile(at: item.url)
        }
    }

    /// Keep the open viewer and listing in sync after an in-place rewrite so
    /// `contentVersion` changes and previews reload.
    private func noteRewrittenFile(at url: URL, pixelSize: CGSize? = nil, duration: TimeInterval? = nil) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map(Int64.init)
        let modified = values?.contentModificationDate
        if let index = mediaItems.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            mediaItems[index].fileSize = size
            mediaItems[index].modifiedAt = modified
            if let pixelSize {
                mediaItems[index].width = Int(pixelSize.width.rounded())
                mediaItems[index].height = Int(pixelSize.height.rounded())
            }
            if let duration {
                mediaItems[index].duration = duration
            }
            rebuildVisibleItems()
        }
        for (id, snapshot) in infoItems where snapshot.url.standardizedFileURL == url.standardizedFileURL {
            var updated = snapshot
            updated.fileSize = size
            updated.modifiedAt = modified
            if let pixelSize {
                updated.width = Int(pixelSize.width.rounded())
                updated.height = Int(pixelSize.height.rounded())
            }
            if let duration {
                updated.duration = duration
            }
            infoItems[id] = updated
        }
        if let pixelSize {
            cropImageSize = pixelSize
        }
    }

    /// Fold duration and audio-stream details discovered by a visible list row
    /// back onto the item so later sorts can use them. Re-sorting is deferred
    /// and coalesced so a folder of rows loading metadata does not reshuffle
    /// on every cell.
    func noteListMetadata(for id: MediaItem.ID, _ metadata: MediaMetadataService.Metadata) {
        guard let index = mediaItems.firstIndex(where: { $0.id == id }) else { return }
        var item = mediaItems[index]
        var changed = false

        func assign<Value: Equatable>(_ current: inout Value?, _ incoming: Value?) {
            guard let incoming, current != incoming else { return }
            current = incoming
            changed = true
        }

        assign(&item.duration, metadata.duration)
        assign(&item.width, metadata.width)
        assign(&item.height, metadata.height)
        assign(&item.bitRate, metadata.bitRate)
        assign(&item.sampleRate, metadata.sampleRate)
        assign(&item.channelCount, metadata.channelCount)

        guard changed else { return }
        mediaItems[index] = item
        if sortKey.usesDeferredMetadata {
            scheduleDeferredSortRefresh()
        }
    }

    private func scheduleDeferredSortRefresh() {
        sortRefreshTask?.cancel()
        sortRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            rebuildVisibleItems()
        }
    }

    private static let thumbnailSizeKey = "thumbnailSize"
    private static let libraryTabKey = "libraryTab"
    private static let sortKeyKey = "sortKey"
    private static let sortAscendingKey = "sortAscending"

    private let rootStore = RootFolderStore()
    private let libraryRepository = LibraryRepository()
    private let standardFolderStore = StandardFolderStore()
    private let scanExclusionStore = FolderScanExclusionStore()
    private let clipboardStore = ClipboardHistoryStore()
    private let onboardingStore: OnboardingStore
    private var scanTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var fileSystemMonitor: FileSystemMonitor?
    private var monitorRefreshTask: Task<Void, Never>?
    private var treeRefreshTask: Task<Void, Never>?
    private var pendingStructuralRefresh = false
    private var activeScanID: UUID?
    private var activeMediaLoadID: UUID?
    private var clipboardMonitorTask: Task<Void, Never>?
    private var lastPasteboardChangeCount: Int?
    private var sortRefreshTask: Task<Void, Never>?
    private var commandPaletteIndexTask: Task<Void, Never>?
    private var comparePreparationTask: Task<Void, Never>?
    private var pendingCommandPaletteOpen: CommandPaletteFileLocation?

    /// Derived indexes are rebuilt only when the visible ordering changes. They
    /// are deliberately ignored by Observation: UI dependencies belong to the
    /// source arrays, while selection/navigation uses these for constant-time
    /// identity resolution.
    @ObservationIgnored private var orderedItemByID: [MediaItem.ID: MediaItem] = [:]
    @ObservationIgnored private var orderedItemIndexByID: [MediaItem.ID: Int] = [:]
    @ObservationIgnored private var selectionSnapshot: Set<MediaItem.ID> = []
    @ObservationIgnored private var selectionStateByID: [MediaItem.ID: MediaItemSelectionState] = [:]

    // MARK: - Lifecycle

    convenience init() {
        self.init(onboardingStore: OnboardingStore())
    }

    init(onboardingStore: OnboardingStore) {
        self.onboardingStore = onboardingStore
        isWelcomePresented = onboardingStore.shouldPresent

        PersistentMediaCache.scheduleMaintenance()

        let storedSize = UserDefaults.standard.object(forKey: Self.thumbnailSizeKey) as? Double
        thumbnailSize = storedSize.map(Self.clampedThumbnailSize) ?? Self.defaultThumbnailSize

        let storedTab = UserDefaults.standard.string(forKey: Self.libraryTabKey)
            .flatMap(MediaLibraryTab.init(rawValue:))
        libraryTab = storedTab ?? .all

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

    @discardableResult
    func addRootFolder() -> URL? {
        guard let url = rootStore.addFolder() else { return nil }
        loadError = nil
        restartFilesystemMonitoring()
        rescanRoots()
        return url
    }

    /// Add one or more folders dropped from Finder, refreshing the library once
    /// after the complete batch has been persisted.
    @discardableResult
    func addRootFolders(_ urls: [URL]) -> Bool {
        guard !rootStore.addFolders(urls).isEmpty else { return false }
        loadError = nil
        restartFilesystemMonitoring()
        rescanRoots()
        return true
    }

    func removeRootFolder(id: MediaFolder.ID) {
        let url = URL(fileURLWithPath: id)
        scanExclusionStore.restoreHidden(under: url)
        rootStore.removeFolder(url)
        if selectedSource == .folder(id) {
            selectedSource = nil
            setMediaItems([])
        }
        restartFilesystemMonitoring()
        rescanRoots()
    }

    /// Hide a subdirectory from the sidebar and skip it on future scans.
    /// Root folders use `removeRootFolder` instead.
    func hideSubfolder(_ folder: MediaFolder) {
        guard !folder.isRoot else { return }
        scanExclusionStore.exclude(folder.url)
        rootTrees = rootTrees.compactMap { removingFolder($0, id: folder.id) }
        if case .folder(let selection) = selectedSource, isFolder(selection, under: folder.id) {
            selectedSource = nil
            setMediaItems([])
        }
        rescanRoots()
    }

    func hasHiddenSubfolders(under folder: MediaFolder) -> Bool {
        scanExclusionStore.hiddenCount(under: folder.url) > 0
    }

    func restoreHiddenSubfolders(under folder: MediaFolder) {
        guard scanExclusionStore.restoreHidden(under: folder.url) > 0 else { return }
        rescanRoots()
    }

    // MARK: - Creator organization

    var canOrganizeSelection: Bool {
        if let viewerItem { return viewerItem.libraryID != nil }
        return selectedItemIDs.contains { orderedItemByID[$0]?.libraryID != nil }
    }

    private var selectedLibraryAssetIDs: [UUID] {
        itemsForAction(clicked: nil).compactMap(\.libraryID)
    }

    /// The items a context-menu or command would act on, without the selection
    /// side effect of `itemsForAction`. Safe to call while building menu labels.
    func actionItemsPreview(clicked item: MediaItem?) -> [MediaItem] {
        if let item {
            if selectedItemIDs.contains(item.id) {
                return selectedItemsInOrder
            }
            return [item]
        }
        if let viewerItem {
            return [viewerItem]
        }
        return selectedItemsInOrder
    }

    /// Whether every organizable item in the pending action is already a
    /// favorite. Uses hydrated `MediaItem.isFavorite`, so it stays in sync with
    /// what the cell chrome shows without another database read.
    func selectionIsAllFavorite(clicked item: MediaItem? = nil) -> Bool {
        let targets = actionItemsPreview(clicked: item).filter { $0.libraryID != nil }
        return !targets.isEmpty && targets.allSatisfy(\.isFavorite)
    }

    /// Whether `tag` is applied to every organizable item in the pending action.
    func selectionHasTag(_ tag: LibraryTag, clicked item: MediaItem? = nil) -> Bool {
        let targets = actionItemsPreview(clicked: item).filter { $0.libraryID != nil }
        return !targets.isEmpty && targets.allSatisfy { $0.tags.contains(where: { $0.id == tag.id }) }
    }

    func createTag(name: String, color: LibraryTagColor, applyingToSelected: Bool = false) {
        let assetIDs = applyingToSelected ? selectedLibraryAssetIDs : []
        Task {
            do {
                let tag = try await libraryRepository.createTag(name: name, color: color)
                if !assetIDs.isEmpty {
                    try await libraryRepository.setTag(tag.id, on: assetIDs, enabled: true)
                }
                await refreshOrganization(reloadSelection: true)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func createTag(name: String, color: LibraryTagColor, applyingTo item: MediaItem) {
        guard let assetID = item.libraryID else { return }
        Task {
            do {
                let tag = try await libraryRepository.createTag(name: name, color: color)
                try await libraryRepository.setTag(tag.id, on: [assetID], enabled: true)
                await refreshOrganization(reloadSelection: true)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func updateTag(_ tag: LibraryTag, name: String, color: LibraryTagColor) {
        Task {
            do {
                try await libraryRepository.updateTag(
                    id: tag.id,
                    name: name,
                    color: color,
                    mergeOnConflict: false
                )
                await refreshOrganization(reloadSelection: true)
            } catch let error as LibraryRepository.RepositoryError {
                if case .duplicateName = error {
                    // Renaming onto an existing tag is only destructive if the
                    // user really wants to combine them, so confirm first.
                    pendingTagMerge = PendingTagMerge(tag: tag, name: name, color: color)
                } else {
                    organizationError = error.localizedDescription
                }
            } catch {
                organizationError = error.localizedDescription
            }
        }
    }

    func confirmPendingTagMerge() {
        guard let pending = pendingTagMerge else { return }
        pendingTagMerge = nil
        Task {
            do {
                try await libraryRepository.updateTag(
                    id: pending.tag.id,
                    name: pending.name,
                    color: pending.color,
                    mergeOnConflict: true
                )
                if selectedSource == .tag(pending.tag.id) { selectedSource = .favorites }
                await refreshOrganization(reloadSelection: true)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func deleteTag(_ tag: LibraryTag) {
        Task {
            do {
                try await libraryRepository.deleteTag(id: tag.id)
                if selectedSource == .tag(tag.id) { selectedSource = .favorites }
                await refreshOrganization(reloadSelection: true)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func setTag(_ tag: LibraryTag, enabled: Bool, clicked item: MediaItem? = nil) {
        let ids = itemsForAction(clicked: item).compactMap(\.libraryID)
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await libraryRepository.setTag(tag.id, on: ids, enabled: enabled)
                await refreshOrganization(reloadSelection: true)
            } catch { organizationError = error.localizedDescription }
        }
    }

    /// Change a tag on exactly one file. Get Info is item-specific even when the
    /// inspected file also belongs to a larger browser selection.
    func setTag(_ tag: LibraryTag, enabled: Bool, on item: MediaItem) {
        guard let assetID = item.libraryID else { return }
        Task {
            do {
                try await libraryRepository.setTag(tag.id, on: [assetID], enabled: enabled)
                await refreshOrganization(reloadSelection: true)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func tagIDs(for item: MediaItem) async -> Set<UUID> {
        guard let assetID = item.libraryID else { return [] }
        return (try? await libraryRepository.tagIDs(for: [assetID])) ?? []
    }

    func tagsAppliedToEverySelectedItem(clicked item: MediaItem? = nil) async -> Set<UUID> {
        let ids = itemsForAction(clicked: item).compactMap(\.libraryID)
        return (try? await libraryRepository.tagIDs(for: ids)) ?? []
    }

    func toggleFavorite(clicked item: MediaItem? = nil) {
        let ids = itemsForAction(clicked: item).compactMap(\.libraryID)
        guard !ids.isEmpty else { return }
        Task {
            do {
                let alreadyFavorite = try await libraryRepository.allFavorite(assetIDs: ids)
                try await libraryRepository.setFavorite(!alreadyFavorite, assetIDs: ids)
                await refreshOrganization(reloadSelection: true)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func createCollection(name: String, addingSelected: Bool = false) {
        let ids = addingSelected ? selectedLibraryAssetIDs : []
        Task {
            do {
                let collection = try await libraryRepository.createCollection(name: name)
                if !ids.isEmpty { try await libraryRepository.add(assetIDs: ids, to: collection.id) }
                await refreshOrganization(reloadSelection: false)
                selectedSource = .collection(collection.id)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func renameCollection(_ collection: MediaCollection, to name: String) {
        Task {
            do {
                try await libraryRepository.renameCollection(id: collection.id, name: name)
                await refreshOrganization(reloadSelection: false)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func deleteCollection(_ collection: MediaCollection) {
        Task {
            do {
                try await libraryRepository.deleteCollection(id: collection.id)
                if selectedSource == .collection(collection.id) { selectedSource = .favorites }
                await refreshOrganization(reloadSelection: false)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func addToCollection(_ collection: MediaCollection, clicked item: MediaItem? = nil) {
        let ids = itemsForAction(clicked: item).compactMap(\.libraryID)
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await libraryRepository.add(assetIDs: ids, to: collection.id)
                await refreshOrganization(reloadSelection: selectedSource == .collection(collection.id))
            } catch { organizationError = error.localizedDescription }
        }
    }

    /// Handle a Finder/Flicksy drop of file URLs onto a collection. A drop is
    /// accepted only when every supported media file it carries is already inside
    /// an added root; non-media files are ignored. Returns whether the drop was
    /// accepted so the drop target can reflect it.
    @discardableResult
    func addURLs(_ urls: [URL], to collection: MediaCollection) -> Bool {
        let roots = rootStore.urls
        let supported = urls.filter { Self.isSupportedMediaURL($0) }
        guard !supported.isEmpty else { return false }
        guard supported.allSatisfy({ Self.isURL($0, insideAnyOf: roots) }) else {
            organizationError = "Only media inside an added folder can be added to a collection."
            return false
        }
        Task {
            do {
                let ids = try await libraryRepository.assetIDs(for: supported, roots: roots)
                try await libraryRepository.add(assetIDs: ids, to: collection.id)
                await refreshOrganization(reloadSelection: selectedSource == .collection(collection.id))
            } catch { organizationError = error.localizedDescription }
        }
        return true
    }

    /// Whether a URL points at a media type Flicksy indexes. Uses the filename
    /// extension so no filesystem access is needed during a drag.
    nonisolated static func isSupportedMediaURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return MediaType(contentType: type) != nil
    }

    nonisolated static func isURL(_ url: URL, insideAnyOf roots: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return path == rootPath || path.hasPrefix(prefix)
        }
    }

    func removeSelectedFromCollection() {
        guard let collectionID = selectedCollectionID else { return }
        let ids = selectedLibraryAssetIDs
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await libraryRepository.remove(assetIDs: ids, from: collectionID)
                await refreshOrganization(reloadSelection: true)
            } catch { organizationError = error.localizedDescription }
        }
    }

    /// Selection snapshot used to build contextual command-palette actions.
    var commandPaletteSelectionItems: [MediaItem] {
        actionItemsPreview(clicked: nil)
    }

    func duplicateCommandPaletteSelection() {
        guard let first = commandPaletteSelectionItems.first else { return }
        duplicate(clicked: first)
    }

    func copyCommandPaletteSelection() {
        guard let first = commandPaletteSelectionItems.first else { return }
        copySelectedFiles(clicked: first)
    }

    func copyCommandPaletteSelectionPath() {
        guard let first = commandPaletteSelectionItems.first else { return }
        copyPath(clicked: first)
    }

    func revealCommandPaletteSelection() {
        guard let first = commandPaletteSelectionItems.first else { return }
        revealInFinder(clicked: first)
    }

    func trashCommandPaletteSelection() {
        guard let first = commandPaletteSelectionItems.first else { return }
        moveSelectedFilesToTrashExplicitly(clicked: first)
    }

    func openCommandPaletteSelection() {
        let items = commandPaletteSelectionItems
        guard let first = items.first else { return }

        if items.count == 1 {
            openFromContextMenu(first)
        } else if items.contains(where: { $0.type != .audio }) {
            // Preserve the complete selection so the viewer playlist can step
            // through just the selected visual items.
            openPreview()
        } else {
            let target = focusedItem.flatMap { focused in
                items.contains(where: { $0.id == focused.id }) ? focused : nil
            } ?? first
            playingAudioID = target.id
        }
    }

    func presentRenameForCommandPaletteSelection() {
        guard commandPaletteSelectionItems.count == 1,
              let item = commandPaletteSelectionItems.first
        else { return }
        dismissCommandPalette()
        renameProposedName = item.name
        renameItemRequest = item
    }

    func confirmCommandPaletteRename() {
        guard let item = renameItemRequest else { return }
        let name = renameProposedName
        renameItemRequest = nil
        rename(item, to: name)
    }

    func removeMissingCollectionItem(_ item: MissingCollectionItem) {
        Task {
            do {
                try await libraryRepository.removeMissingMembership(id: item.id)
                await refreshOrganization(reloadSelection: true)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func locateMissingCollectionItem(_ item: MissingCollectionItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Relink"
        panel.message = "Choose the replacement for \(item.name). It must be inside an added folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let roots = rootStore.urls
        Task {
            do {
                try await libraryRepository.relink(assetID: item.assetID, to: url, roots: roots)
                await refreshOrganization(reloadSelection: true)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func reorderCollectionItem(_ item: MediaItem, before target: MediaItem?) {
        guard sortKey == .manual,
              let collectionID = selectedCollectionID,
              let assetID = item.libraryID
        else { return }
        Task {
            do {
                try await libraryRepository.reorder(
                    collectionID: collectionID,
                    assetID: assetID,
                    before: target?.libraryID
                )
                loadMediaForSelection(preservingInteraction: true)
            } catch { organizationError = error.localizedDescription }
        }
    }

    func reorderCollectionURLs(_ urls: [URL], before target: MediaItem) {
        guard urls.count == 1,
              let item = mediaItems.first(where: { $0.url.standardizedFileURL == urls[0].standardizedFileURL })
        else { return }
        reorderCollectionItem(item, before: target)
    }

    private func refreshOrganization(reloadSelection: Bool) async {
        do {
            async let loadedTags = libraryRepository.tags()
            async let loadedCollections = libraryRepository.collections()
            tags = try await loadedTags
            collections = try await loadedCollections
            invalidateCommandPaletteSearchIndex()
            if reloadSelection { loadMediaForSelection(preservingInteraction: true) }
        } catch { organizationError = error.localizedDescription }
    }

    // MARK: - Finder / pasteboard

    /// Items a context-menu or keyboard command should act on. Right-clicking an
    /// unselected item acts on that item alone (and selects it); right-clicking
    /// inside a selection acts on every selected item.
    func itemsForAction(clicked item: MediaItem?) -> [MediaItem] {
        if let item {
            if selectedItemIDs.contains(item.id) {
                return selectedItemsInOrder
            }
            selectItem(item)
            return [item]
        }
        if let viewerItem {
            return [viewerItem]
        }
        return selectedItemsInOrder
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

    /// The single file targeted by the Get Info menu command.
    var getInfoTarget: MediaItem? {
        if let viewerItem { return viewerItem }
        if let focusedItemID,
           let focused = orderedItemByID[focusedItemID] {
            return focused
        }
        return selectedItemsInOrder.first
    }

    /// MP3s the File menu should open in Edit Meta Tags: the viewer clip, or every
    /// writable MP3 in the selection.
    var editAudioTagsTargets: [MediaItem] {
        if let viewerItem {
            return AudioTagService.canWrite(url: viewerItem.url) ? [viewerItem] : []
        }
        let selected = selectedItemsInOrder.filter { AudioTagService.canWrite(url: $0.url) }
        if !selected.isEmpty { return selected }
        if let item = getInfoTarget, AudioTagService.canWrite(url: item.url) {
            return [item]
        }
        return []
    }

    func presentAudioTagsEditor(clicked item: MediaItem? = nil) {
        let targets: [MediaItem]
        if let item {
            targets = itemsForAction(clicked: item).filter { AudioTagService.canWrite(url: $0.url) }
        } else {
            targets = editAudioTagsTargets
        }
        guard !targets.isEmpty else { return }
        editAudioTagsRequest = AudioTagsEditRequest(items: targets)
    }

    func registerInfoItem(_ item: MediaItem) {
        infoItems[item.id] = item
    }

    func mediaItemForInfo(id: MediaItem.ID) -> MediaItem? {
        mediaItems.first(where: { $0.id == id }) ?? infoItems[id]
    }

    /// Open the clicked item (or every selected item when it is part of the
    /// selection) in a specific installed application.
    func openWith(_ applicationURL: URL, clicked item: MediaItem) {
        let urls = itemsForAction(clicked: item).map(\.url)
        guard !urls.isEmpty else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { _, error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                self?.loadError = "The selected items could not be opened with \(applicationURL.deletingPathExtension().lastPathComponent)."
            }
        }
    }

    /// Copy the clicked item, or all selected items when the click is inside the
    /// current selection. Large media files are copied away from the main actor.
    func duplicate(clicked item: MediaItem) {
        guard !isClipboardSelected else { return }
        let targets = itemsForAction(clicked: item).map(\.url)
        guard !targets.isEmpty else { return }

        Task {
            let failed = await Task.detached(priority: .userInitiated) {
                var reservedDestinations: Set<URL> = []
                var failed = false

                for source in targets {
                    let destination = Self.duplicateDestination(
                        for: source,
                        reserving: reservedDestinations
                    )
                    reservedDestinations.insert(destination)
                    do {
                        try FileManager.default.copyItem(at: source, to: destination)
                    } catch {
                        failed = true
                    }
                }
                return failed
            }.value

            refreshAfterFileMutation()
            if failed {
                loadError = "Some selected items could not be duplicated."
            }
        }
    }

    /// Rename one file in place. The extension is editable, matching Finder.
    func rename(_ item: MediaItem, to proposedName: String) {
        guard !isClipboardSelected else { return }
        let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty,
              newName != ".",
              newName != "..",
              !newName.contains("/")
        else {
            loadError = "Enter a valid filename that does not contain a slash."
            return
        }

        let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        guard destination != item.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path)
                || Self.urlsReferToSameFile(item.url, destination)
        else {
            loadError = "A file named \(newName) already exists in this folder."
            return
        }

        selectItem(item)
        Task {
            let succeeded = await Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.moveItem(at: item.url, to: destination)
                    return true
                } catch {
                    return false
                }
            }.value

            if succeeded {
                refreshAfterFileMutation()
            } else {
                loadError = "\(item.name) could not be renamed."
            }
        }
    }

    nonisolated private static func duplicateDestination(
        for source: URL,
        reserving reserved: Set<URL>
    ) -> URL {
        let directory = source.deletingLastPathComponent()
        let fileExtension = source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        var copyNumber = 1

        while true {
            let suffix = copyNumber == 1 ? " copy" : " copy \(copyNumber)"
            let filename = fileExtension.isEmpty
                ? baseName + suffix
                : baseName + suffix + "." + fileExtension
            let candidate = directory.appendingPathComponent(filename)
            if !reserved.contains(candidate),
               !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            copyNumber += 1
        }
    }

    nonisolated private static func pasteDestination(
        for source: URL,
        in directory: URL,
        reserving reserved: Set<URL>
    ) -> URL {
        let original = directory.appendingPathComponent(source.lastPathComponent)
        if !reserved.contains(original),
           !FileManager.default.fileExists(atPath: original.path) {
            return original
        }

        // Rebase the duplicate-name calculation into the destination folder.
        return duplicateDestination(for: original, reserving: reserved)
    }

    nonisolated private static func urlsReferToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let lhsID = try? lhs.resourceValues(forKeys: keys).fileResourceIdentifier,
              let rhsID = try? rhs.resourceValues(forKeys: keys).fileResourceIdentifier
        else { return false }
        return lhsID.isEqual(rhsID)
    }

    private func refreshAfterFileMutation(rescanTree: Bool = false) {
        invalidateCommandPaletteSearchIndex()
        if rescanTree {
            rescanRoots()
        }
        loadMediaForSelection(preservingInteraction: true)
    }

    func revealInFinder(clicked item: MediaItem? = nil) {
        let urls = itemsForAction(clicked: item).map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealInFinder(_ folder: MediaFolder) {
        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
    }

    func copyPath(clicked item: MediaItem? = nil) {
        let urls = itemsForAction(clicked: item).map(\.url)
        guard !urls.isEmpty else { return }
        let string = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        pasteboardContainsFileURLs = false
    }

    /// Copy the selected files themselves so they can be pasted into Finder.
    func copySelectedFiles(clicked item: MediaItem? = nil) {
        let urls = itemsForAction(clicked: item).map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
        pasteboardContainsFileURLs = true
    }

    /// Whether the active source represents a writable filesystem folder. The
    /// virtual Clipboard source deliberately has no paste destination.
    var canPasteIntoSelectedFolder: Bool {
        selectedFolderURL != nil
    }

    var canPasteFiles: Bool {
        canPasteIntoSelectedFolder && pasteboardContainsFileURLs
    }

    /// Copy file URLs from the system pasteboard into the active folder. Existing
    /// names are kept safe with Finder-style "copy" suffixes rather than replaced.
    func pasteFiles() {
        guard let destinationFolder = selectedFolderURL else { return }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let sources = (NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL]) ?? []
        guard !sources.isEmpty else { return }

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var reservedDestinations: Set<URL> = []
                var failed = false
                var copiedDirectory = false

                for source in sources {
                    if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        copiedDirectory = true
                    }
                    let destination = Self.pasteDestination(
                        for: source,
                        in: destinationFolder,
                        reserving: reservedDestinations
                    )
                    reservedDestinations.insert(destination)
                    do {
                        try FileManager.default.copyItem(at: source, to: destination)
                    } catch {
                        failed = true
                    }
                }
                return (failed: failed, copiedDirectory: copiedDirectory)
            }.value

            refreshAfterFileMutation(rescanTree: result.copiedDirectory)
            if result.failed {
                loadError = "Some clipboard items could not be pasted into this folder."
            }
        }
    }

    private var selectedFolderURL: URL? {
        switch selectedSource {
        case .folder(let id):
            URL(fileURLWithPath: id, isDirectory: true)
        case .standardFolder(let folder):
            urlForStandardFolder(folder)
        case .favorites, .tag, .collection, .clipboard, nil:
            nil
        }
    }

    /// URLs to put on the pasteboard for a drag starting at `item`.
    func prepareDrag(from item: MediaItem) -> [URL] {
        if selectedItemIDs.contains(item.id) {
            return selectedItemsInOrder.map(\.url)
        }
        selectItem(item)
        return [item.url]
    }

    /// Move an internal media drag into a real folder shown in the sidebar.
    /// External Finder drags are deliberately not accepted here: a drop should
    /// never unexpectedly move files that were not dragged out of Flicksy.
    @discardableResult
    func moveDraggedMedia(_ urls: [URL], into destinationFolder: URL) -> Bool {
        guard !isClipboardSelected, !urls.isEmpty else { return false }

        let visibleURLs = Set(mediaItems.map { $0.url.standardizedFileURL })
        let sources = urls.map(\.standardizedFileURL)
        guard sources.allSatisfy(visibleURLs.contains) else { return false }

        let destination = destinationFolder.standardizedFileURL
        guard (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              sources.contains(where: {
                  $0.deletingLastPathComponent().standardizedFileURL != destination
              })
        else { return false }

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                MediaFileMover.move(sources, into: destination)
            }.value

            if result.movedCount > 0 {
                refreshAfterFileMutation(rescanTree: true)
            }
            if result.hasFailures {
                loadError = Self.fileMoveErrorMessage(result, destination: destination)
            }
        }
        return true
    }

    @discardableResult
    func moveDraggedMedia(_ urls: [URL], into folder: StandardBrowserFolder) -> Bool {
        guard let destination = urlForStandardFolder(folder) else { return false }
        return moveDraggedMedia(urls, into: destination)
    }

    nonisolated private static func fileMoveErrorMessage(
        _ result: MediaFileMoveResult,
        destination: URL
    ) -> String {
        let folderName = destination.lastPathComponent
        if !result.conflictingNames.isEmpty, result.failedNames.isEmpty {
            if result.conflictingNames.count == 1 {
                return "A file was not moved to \(folderName) because a file with the same name already exists there."
            }
            return "Some files were not moved to \(folderName) because files with the same names already exist there."
        }
        return "Some files could not be moved to \(folderName)."
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
        pasteboardContainsFileURLs = pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )

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
        ) { [weak self] hasStructuralChanges in
            self?.filesystemDidChange(hasStructuralChanges: hasStructuralChanges)
        }
    }

    /// Editors often emit several rename/write events for one save. Coalesce the
    /// burst so large roots are scanned once, and cancel an obsolete pending pass
    /// if more changes arrive before it starts.
    private func filesystemDidChange(hasStructuralChanges: Bool) {
        invalidateCommandPaletteSearchIndex()
        pendingStructuralRefresh = pendingStructuralRefresh || hasStructuralChanges

        // Keep the selected directory responsive independently of the recursive
        // smart-sidebar refresh.
        monitorRefreshTask?.cancel()
        monitorRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            if case .folder = selectedSource {
                loadMediaForSelection(preservingInteraction: true)
            } else if case .standardFolder = selectedSource {
                loadMediaForSelection(preservingInteraction: true)
            }
        }

        // File-only changes can affect smart-folder visibility too, but they do
        // not need to compete with the visible-folder reload. Let them settle;
        // directory changes use the shorter delay.
        treeRefreshTask?.cancel()
        treeRefreshTask = Task {
            let delay: Duration = pendingStructuralRefresh ? .milliseconds(450) : .seconds(2)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            pendingStructuralRefresh = false
            rescanRoots()
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
                let policy = scanExclusionStore.policy
                for url in urls {
                    let tree = try await FolderScanner.buildTree(for: url, policy: policy)
                    trees.append(tree)
                }
            } catch is CancellationError {
                return
            } catch {
                loadError = "Some folders could not be read. Try removing and re-adding them."
            }

            guard !Task.isCancelled else { return }
            rootTrees = trees

            // Catalog reconciliation is independent from the visible folder
            // listing. It walks only explicitly added roots and preserves
            // organization records for files that are temporarily unavailable.
            await reconcileLibrary(roots: urls)

            // Drop a selection that no longer exists in the refreshed tree.
            if case .folder(let selection) = selectedSource,
               !folderExists(withID: selection, in: trees) {
                selectedSource = nil
                setMediaItems([])
            }
        }
    }

    private func reconcileLibrary(roots: [URL]) async {
        isIndexingLibrary = true
        defer { isIndexingLibrary = false }
        do {
            try await libraryRepository.reconcile(roots: roots, policy: scanExclusionStore.policy)
            await refreshOrganization(reloadSelection: isLibrarySourceSelected)
        } catch is CancellationError {
            return
        } catch {
            organizationError = "The media library could not be updated: \(error.localizedDescription)"
        }
    }

    private func loadMediaForSelection(preservingInteraction: Bool = false) {
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
                switch source {
                case .favorites:
                    try await loadLibraryQuery(.favorites, preservingInteraction: preservingInteraction)
                case .tag(let id):
                    try await loadLibraryQuery(.tag(id), preservingInteraction: preservingInteraction)
                case .collection(let id):
                    try await loadLibraryQuery(.collection(id), preservingInteraction: preservingInteraction)
                case .clipboard:
                    let items = await clipboardStore.items()
                    clipboardItemCount = items.count
                    guard !Task.isCancelled else { return }
                    setMediaItems(items)
                case .standardFolder(let folder):
                    guard let url = urlForStandardFolder(folder) else {
                        setMediaItems([])
                        loadError = "Access to \(folder.title) was not granted."
                        return
                    }
                    restartFilesystemMonitoring()
                    try await loadMediaDirectory(
                        url,
                        loadID: loadID,
                        preservingInteraction: preservingInteraction
                    )
                case .folder(let id):
                    try await loadMediaDirectory(
                        URL(fileURLWithPath: id, isDirectory: true),
                        loadID: loadID,
                        preservingInteraction: preservingInteraction
                    )
                }
                resolvePendingCommandPaletteOpen()
                if pendingCommandPaletteOpen?.source == source {
                    pendingCommandPaletteOpen = nil
                }
            } catch is CancellationError {
                return
            } catch {
                pendingCommandPaletteOpen = nil
                setMediaItems([])
                loadError = source == .clipboard
                    ? "Clipboard history could not be loaded."
                    : "This folder could not be read."
            }
        }
    }

    private func loadLibraryQuery(
        _ query: LibraryQuery,
        preservingInteraction: Bool
    ) async throws {
        let result = try await libraryRepository.query(query)
        try Task.checkCancellation()
        missingCollectionItems = result.missingItems
        replaceMediaItems(result.items, resetInteraction: !preservingInteraction)
    }

    /// Race a cached listing against cancellable live batches. Main-actor updates
    /// are deliberately chunked so SwiftUI can render and accept input between
    /// large-directory scan results.
    private func loadMediaDirectory(
        _ directory: URL,
        loadID: UUID,
        preservingInteraction: Bool
    ) async throws {
        if !preservingInteraction {
            setMediaItems([])
        }

        var freshItems: [MediaItem] = []
        var pendingItems: [MediaItem] = []
        var receivedFirstBatch = false
        var displayedCache = false

        for await event in Self.folderLoadEvents(for: directory) {
            try Task.checkCancellation()
            guard activeMediaLoadID == loadID else { throw CancellationError() }

            switch event {
            case .cached(let items):
                guard !receivedFirstBatch, !items.isEmpty else { continue }
                let resolved = try await libraryRepository.attachLibraryIdentity(
                    to: items,
                    roots: rootStore.urls
                )
                replaceMediaItems(resolved, resetInteraction: !preservingInteraction)
                displayedCache = true
                await Task.yield()

            case .failed:
                throw CocoaError(.fileReadUnknown)

            case .liveBatch(let batch):
                let resolvedBatch = try await libraryRepository.attachLibraryIdentity(
                    to: batch,
                    roots: rootStore.urls
                )
                freshItems.append(contentsOf: batch)
                if receivedFirstBatch {
                    pendingItems.append(contentsOf: resolvedBatch)
                    if pendingItems.count >= 1_000 {
                        appendMediaItems(pendingItems)
                        pendingItems.removeAll(keepingCapacity: true)
                    }
                } else {
                    // Drop the stale cache only once live data is ready to replace it.
                    replaceMediaItems(
                        resolvedBatch,
                        resetInteraction: !displayedCache && !preservingInteraction
                    )
                    receivedFirstBatch = true
                }

                // Give rendering and input handling an opportunity between chunks.
                await Task.yield()
            }
        }

        if !pendingItems.isEmpty {
            appendMediaItems(pendingItems)
        }

        try Task.checkCancellation()
        guard activeMediaLoadID == loadID else { throw CancellationError() }

        if !receivedFirstBatch {
            replaceMediaItems([], resetInteraction: !preservingInteraction)
        }
        preferPopulatedTab()

        let listingToCache = freshItems
        Task.detached(priority: .background) {
            FolderListingCache.store(listingToCache, for: directory)
        }
    }

    nonisolated private static func folderLoadEvents(
        for directory: URL
    ) -> AsyncStream<FolderLoadEvent> {
        AsyncStream { continuation in
            let cacheTask = Task.detached(priority: .utility) {
                if let cached = FolderListingCache.load(for: directory),
                   !Task.isCancelled {
                    continuation.yield(.cached(cached))
                }
            }

            let scanTask = Task.detached(priority: .userInitiated) {
                do {
                    for try await batch in FolderScanner.mediaItemBatches(in: directory) {
                        try Task.checkCancellation()
                        continuation.yield(.liveBatch(batch))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.failed)
                    continuation.finish()
                }
            }

            continuation.onTermination = { @Sendable _ in
                cacheTask.cancel()
                scanTask.cancel()
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
        let wasAvailable = standardFolderStore.availableURL(for: folder) != nil
        let url = standardFolderStore.url(for: folder)
        if !wasAvailable, url != nil {
            invalidateCommandPaletteSearchIndex()
        }
        return url
    }

    /// Replace the current listing, rebuild the per-section splits, and drop any
    /// playback or viewer state that referred to the previous folder.
    private func setMediaItems(_ items: [MediaItem]) {
        missingCollectionItems = []
        replaceMediaItems(items, resetInteraction: true)
    }

    private func replaceMediaItems(_ items: [MediaItem], resetInteraction: Bool) {
        mediaItems = items
        cardAspectRatio = Self.cardAspectRatio(for: items)
        if resetInteraction {
            playingVideoID = nil
            playingAudioID = nil
            viewerItemID = nil
            selectedItemIDs = []
            selectionStateByID.removeAll(keepingCapacity: true)
            selectionAnchorID = nil
            focusedItemID = nil
        }
        rebuildVisibleItems()
        preferPopulatedTab()
        resolvePendingCommandPaletteOpen()
    }

    private func appendMediaItems(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        mediaItems.append(contentsOf: items)
        // Incremental filesystem items intentionally have no eager dimensions,
        // so their stable initial layout is square.
        cardAspectRatio = 1
        rebuildVisibleItems()
    }

    // MARK: - Command palette search

    func openCommandPaletteDestination(_ destination: BrowserDestination) {
        dismissCommandPalette()
        go(to: destination.source)
    }

    func openCommandPaletteFile(_ location: CommandPaletteFileLocation) {
        dismissCommandPalette()
        pendingCommandPaletteOpen = location
        if selectedSource == location.source {
            resolvePendingCommandPaletteOpen()
            if pendingCommandPaletteOpen != nil, !isLoadingMedia {
                pendingCommandPaletteOpen = nil
            }
        } else {
            selectedSource = location.source
        }
    }

    private func resolvePendingCommandPaletteOpen() {
        guard let pending = pendingCommandPaletteOpen,
              pending.source == selectedSource,
              let item = Self.resolveCommandPaletteItem(pending, in: mediaItems)
        else { return }

        pendingCommandPaletteOpen = nil
        selectedItemIDs = [item.id]
        focusedItemID = item.id
        selectionAnchorID = item.id

        switch item.type {
        case .image, .video:
            libraryTab = .visual
            openViewer(item)
        case .audio:
            libraryTab = .audio
            playingAudioID = item.id
            isAudioPlaying = true
        }
    }

    nonisolated static func resolveCommandPaletteItem(
        _ pending: CommandPaletteFileLocation,
        in items: [MediaItem]
    ) -> MediaItem? {
        items.first { item in
            if let libraryID = pending.item.libraryID,
               item.libraryID == libraryID {
                return true
            }
            return item.url.standardizedFileURL == pending.item.url.standardizedFileURL
        }
    }

    func invalidateCommandPaletteSearchIndex() {
        commandPaletteIndexTask?.cancel()
        commandPaletteIndexTask = nil
        commandPaletteSearchIndex = nil
        isLoadingCommandPaletteIndex = false
        if isCommandPalettePresented {
            loadCommandPaletteIndexIfNeeded()
        }
    }

    private func loadCommandPaletteIndexIfNeeded() {
        guard commandPaletteSearchIndex == nil,
              commandPaletteIndexTask == nil
        else { return }

        let destinations = browserDestinations
        let standardLocations = StandardBrowserFolder.allCases.compactMap { folder in
            standardFolderStore.availableURL(for: folder).map { (folder, $0.standardizedFileURL) }
        }

        isLoadingCommandPaletteIndex = true
        commandPaletteIndexTask = Task {
            async let libraryRecords = (try? libraryRepository.searchRecords()) ?? []
            var standardItems: [(StandardBrowserFolder, URL, [MediaItem])] = []
            for (folder, url) in standardLocations {
                let items = (try? await FolderScanner.mediaItems(in: url)) ?? []
                standardItems.append((folder, url, items))
            }

            let records = await libraryRecords
            guard !Task.isCancelled else { return }
            commandPaletteSearchIndex = Self.makeCommandPaletteSearchIndex(
                destinations: destinations,
                libraryRecords: records,
                standardItems: standardItems
            )
            commandPaletteIndexTask = nil
            isLoadingCommandPaletteIndex = false
        }
    }

    nonisolated static func makeCommandPaletteSearchIndex(
        destinations: [BrowserDestination],
        libraryRecords: [LibrarySearchRecord],
        standardItems: [(StandardBrowserFolder, URL, [MediaItem])]
    ) -> CommandPaletteSearchIndex {
        struct MergedFile {
            var item: MediaItem
            var collections: [MediaCollection]
        }

        var filesByPath: [String: MergedFile] = [:]
        for record in libraryRecords {
            filesByPath[record.item.url.standardizedFileURL.path] = MergedFile(
                item: record.item,
                collections: record.collections
            )
        }
        for (_, _, items) in standardItems {
            for item in items {
                let key = item.url.standardizedFileURL.path
                if filesByPath[key] == nil {
                    filesByPath[key] = MergedFile(item: item, collections: [])
                }
            }
        }

        let standardByPath = Dictionary(uniqueKeysWithValues: standardItems.map {
            ($0.1.standardizedFileURL.path, $0.0)
        })
        var locations: [CommandPaletteFileLocation] = []
        var seenLocationIDs: Set<String> = []

        func append(_ location: CommandPaletteFileLocation) {
            if seenLocationIDs.insert(location.id).inserted {
                locations.append(location)
            }
        }

        for merged in filesByPath.values {
            let item = merged.item
            let parent = item.url.deletingLastPathComponent().standardizedFileURL
            if let standard = standardByPath[parent.path] {
                append(CommandPaletteFileLocation(
                    item: item,
                    source: .standardFolder(standard),
                    locationTitle: standard.title,
                    locationKind: "Folder"
                ))
            } else {
                append(CommandPaletteFileLocation(
                    item: item,
                    source: .folder(parent.path),
                    locationTitle: parent.lastPathComponent,
                    locationKind: "Folder"
                ))
            }

            guard item.libraryID != nil else { continue }
            if item.isFavorite {
                append(CommandPaletteFileLocation(
                    item: item,
                    source: .favorites,
                    locationTitle: "Favorites",
                    locationKind: "Library"
                ))
            }
            for tag in item.tags {
                append(CommandPaletteFileLocation(
                    item: item,
                    source: .tag(tag.id),
                    locationTitle: tag.name,
                    locationKind: "Tag"
                ))
            }
            for collection in merged.collections {
                append(CommandPaletteFileLocation(
                    item: item,
                    source: .collection(collection.id),
                    locationTitle: collection.name,
                    locationKind: "Collection"
                ))
            }
        }

        locations.sort {
            let nameOrder = $0.item.name.localizedStandardCompare($1.item.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let kindOrder = $0.locationKind.localizedStandardCompare($1.locationKind)
            if kindOrder != .orderedSame { return kindOrder == .orderedAscending }
            return $0.locationTitle.localizedStandardCompare($1.locationTitle) == .orderedAscending
        }
        return CommandPaletteSearchIndex(destinations: destinations, files: locations)
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

        allItems = sortedItems(visibleItems)
        visualItems = allItems.filter { $0.type == .image || $0.type == .video }
        audioItems = allItems.filter { $0.type == .audio }

        isolateCurrentTab()
    }

    /// Keep selection, playback and the viewer inside the active tab, and drop
    /// anything that refers to a file the current listing no longer contains.
    private func isolateCurrentTab() {
        rebuildOrderedItemIndexes()
        let visibleIDs = Set(orderedItems.map(\.id))
        selectedItemIDs.formIntersection(visibleIDs)

        if libraryTab == .audio {
            playingVideoID = nil
            viewerItemID = nil
        } else if let playingVideoID, !visibleIDs.contains(playingVideoID) {
            self.playingVideoID = nil
        }

        if libraryTab == .visual {
            playingAudioID = nil
        } else if let playingAudioID, !visibleIDs.contains(playingAudioID) {
            self.playingAudioID = nil
        }

        if let viewerItemID, !visibleIDs.contains(viewerItemID) {
            self.viewerItemID = nil
        }

        if let focusedItemID, !visibleIDs.contains(focusedItemID) {
            self.focusedItemID = selectedItemsInOrder.first?.id
        }
        if let selectionAnchorID, !visibleIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = focusedItemID
        }
        if isComparingImages {
            reconcileImageComparison()
        }
    }

    /// If the restored tab is empty for this folder but the other is not, show
    /// the tab that actually has files.
    private func preferPopulatedTab() {
        let hasVisual = mediaItems.contains { $0.type == .image || $0.type == .video }
        let hasAudio = mediaItems.contains { $0.type == .audio }
        switch libraryTab {
        case .all:
            break
        case .visual where !hasVisual && hasAudio:
            libraryTab = .audio
        case .audio where !hasAudio && hasVisual:
            libraryTab = .visual
        default:
            break
        }
    }

    private func sortedItems(_ items: [MediaItem]) -> [MediaItem] {
        if sortKey == .manual, isCollectionSelected {
            return sortAscending ? items : Array(items.reversed())
        }
        return items.sorted { lhs, rhs in
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
        case .manual:
            return nil
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .kind:
            return lhs.kindDescription.localizedStandardCompare(rhs.kindDescription)
        case .added:
            return compareOptional(lhs.addedAt, rhs.addedAt)
        case .modified:
            return compareOptional(lhs.modifiedAt, rhs.modifiedAt)
        case .duration:
            return compareOptional(lhs.duration, rhs.duration)
        case .dimensions:
            return compareOptional(pixelArea(lhs), pixelArea(rhs))
        case .bitRate:
            return compareOptional(lhs.bitRate, rhs.bitRate)
        case .sampleRate:
            return compareOptional(lhs.sampleRate, rhs.sampleRate)
        case .channels:
            return compareOptional(lhs.channelCount, rhs.channelCount)
        case .size:
            return compareOptional(lhs.fileSize, rhs.fileSize)
        }
    }

    private func pixelArea(_ item: MediaItem) -> Int? {
        guard let width = item.width, let height = item.height, width > 0, height > 0 else { return nil }
        return width * height
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

    // MARK: - Selection

    /// Items in the active tab, in the current sort order. Selection, keyboard
    /// navigation and Select All walk this list so they never cross into the
    /// hidden tab.
    var orderedItems: [MediaItem] {
        switch libraryTab {
        case .all: allItems
        case .visual: visualItems
        case .audio: audioItems
        }
    }

    /// The focused item without a linear walk through a potentially huge folder.
    var focusedItem: MediaItem? {
        focusedItemID.flatMap { orderedItemByID[$0] }
    }

    /// Stable, fine-grained highlight state for a rendered row or grid cell.
    func selectionState(for id: MediaItem.ID) -> MediaItemSelectionState {
        if let state = selectionStateByID[id] { return state }
        let state = MediaItemSelectionState(isSelected: selectionSnapshot.contains(id))
        selectionStateByID[id] = state
        return state
    }

    /// Resolve the selection in visible sort order. The common one-item case is
    /// constant time; large range selections avoid an O(k log k) sort by walking
    /// the already ordered array once.
    private var selectedItemsInOrder: [MediaItem] {
        guard !selectedItemIDs.isEmpty else { return [] }
        if selectedItemIDs.count == 1,
           let id = selectedItemIDs.first,
           let item = orderedItemByID[id] {
            return [item]
        }
        if selectedItemIDs.count * 2 >= orderedItems.count {
            return orderedItems.filter { selectedItemIDs.contains($0.id) }
        }
        return selectedItemIDs.compactMap { id -> (Int, MediaItem)? in
            guard let item = orderedItemByID[id],
                  let index = orderedItemIndexByID[id]
            else { return nil }
            return (index, item)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    private func rebuildOrderedItemIndexes() {
        let items = orderedItems
        var itemsByID: [MediaItem.ID: MediaItem] = [:]
        var indicesByID: [MediaItem.ID: Int] = [:]
        itemsByID.reserveCapacity(items.count)
        indicesByID.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            itemsByID[item.id] = item
            indicesByID[item.id] = index
        }
        orderedItemByID = itemsByID
        orderedItemIndexByID = indicesByID
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
        guard let a = orderedItemIndexByID[from],
              let b = orderedItemIndexByID[to]
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

    /// Apply the live result of an empty-space marquee drag. IDs are restricted
    /// to the active tab because visible cell frames can briefly overlap a tab
    /// change while SwiftUI tears down the old lazy container.
    func setMarqueeSelection(_ ids: Set<MediaItem.ID>) {
        let ordered = orderedItems
        let allowedIDs = Set(ordered.map(\.id))
        selectedItemIDs = ids.intersection(allowedIDs)

        if let focusedItemID, selectedItemIDs.contains(focusedItemID) {
            // Keep the keyboard cursor stable while the rectangle grows.
        } else {
            focusedItemID = ordered.first { selectedItemIDs.contains($0.id) }?.id
        }

        if let selectionAnchorID, selectedItemIDs.contains(selectionAnchorID) {
            // Preserve the existing Shift-selection anchor when possible.
        } else {
            selectionAnchorID = focusedItemID
        }
    }

    /// Move the keyboard cursor through the active tab.
    ///
    /// Left/Right step by one; Up/Down step by a full row. Movement clamps at
    /// either end rather than wrapping, matching Finder.
    func moveSelection(_ direction: MoveDirection, columns: Int, extending: Bool) {
        let ordered = orderedItems
        guard !ordered.isEmpty else { return }

        let cols = max(1, columns)
        let currentIndex = focusedItemID.flatMap { orderedItemIndexByID[$0] } ?? 0

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

    /// Selected stills eligible for comparison, preserving browser sort order.
    var selectedImagesForComparison: [MediaItem] {
        selectedItemsInOrder.filter { $0.type == .image }
    }

    var canCompareSelectedImages: Bool {
        selectedImagesForComparison.count >= 2
    }

    /// Every image represented by the comparison thumbnail strip.
    var comparisonImages: [MediaItem] {
        compareItemIDs.compactMap { orderedItemByID[$0] }
    }

    /// Preview-only check used while constructing a context menu. An unselected
    /// click remains a one-item action, matching the rest of the menu.
    func canCompareImages(clicked item: MediaItem?) -> Bool {
        comparisonCandidates(clicked: item).count >= 2
    }

    /// Enter image comparison using either a requested layout or the automatic
    /// orientation heuristic. Missing dimensions are read off the main thread
    /// before automatic comparison becomes active.
    func startImageComparison(
        layout requestedLayout: MediaCompareLayout? = nil,
        clicked item: MediaItem? = nil
    ) {
        let candidates = comparisonCandidates(clicked: item)
        guard candidates.count >= 2 else { return }
        if let requestedLayout, !requestedLayout.isAvailable(for: candidates.count) { return }

        comparePreparationTask?.cancel()

        let preferredID = [viewerItemID, focusedItemID]
            .compactMap { $0 }
            .first { id in candidates.contains(where: { $0.id == id }) }
            ?? candidates[0].id
        let returnID = viewerItemID ?? preferredID

        if viewerItemID == nil {
            openViewer(candidates.first(where: { $0.id == preferredID }) ?? candidates[0])
        } else {
            resetCropSession()
            resetViewerImageZoom()
        }

        compareReturnItemID = returnID

        if let requestedLayout {
            activateImageComparison(
                items: candidates,
                preferredItemID: preferredID,
                layout: requestedLayout
            )
            return
        }

        let candidateIDs = candidates.map(\.id)
        comparePreparationTask = Task {
            let resolved = await Task.detached(priority: .userInitiated) {
                candidates.map { item -> MediaItem in
                    guard item.width == nil || item.height == nil,
                          let size = ThumbnailService.pixelSize(for: item.url)
                    else { return item }
                    var updated = item
                    updated.width = Int(size.width.rounded())
                    updated.height = Int(size.height.rounded())
                    return updated
                }
            }.value

            guard !Task.isCancelled,
                  candidateIDs.allSatisfy({ selectedItemIDs.contains($0) && orderedItemByID[$0] != nil })
            else { return }

            let layout = MediaCompareLayout.automatic(
                for: resolved,
                focusedItemID: preferredID
            )
            activateImageComparison(
                items: candidates,
                preferredItemID: preferredID,
                layout: layout
            )
        }
    }

    func toggleImageComparison() {
        if isComparingImages {
            endImageComparison()
        } else {
            startImageComparison()
        }
    }

    func setImageComparisonLayout(_ layout: MediaCompareLayout) {
        guard isComparingImages,
              layout.isAvailable(for: compareItemIDs.count),
              layout != compareLayout
        else { return }

        compareLayout = layout
        compareSlotItemIDs = MediaComparisonAssignment.resized(
            assignments: compareSlotItemIDs,
            allItemIDs: compareItemIDs,
            capacity: layout.capacity
        )
    }

    /// Assign a thumbnail to a cell. Existing assignments swap; an image from
    /// the overflow strip replaces the target and leaves the displaced image free.
    func assignComparisonImage(_ itemID: MediaItem.ID, toSlot index: Int) {
        guard isComparingImages,
              compareItemIDs.contains(itemID),
              compareSlotItemIDs.indices.contains(index)
        else { return }

        compareSlotItemIDs = MediaComparisonAssignment.assigning(
            itemID: itemID,
            toSlot: index,
            assignments: compareSlotItemIDs,
            allItemIDs: compareItemIDs
        )
    }

    func endImageComparison() {
        let returnID = compareReturnItemID
        clearImageComparisonState()
        if let returnID, visualItems.contains(where: { $0.id == returnID }) {
            viewerItemID = returnID
            focusedItemID = returnID
        }
        resetViewerImageZoom()
    }

    private func comparisonCandidates(clicked item: MediaItem?) -> [MediaItem] {
        let items: [MediaItem]
        if let item {
            items = actionItemsPreview(clicked: item)
        } else {
            items = selectedItemsInOrder
        }
        return items.filter { $0.type == .image }
    }

    private func activateImageComparison(
        items: [MediaItem],
        preferredItemID: MediaItem.ID,
        layout: MediaCompareLayout
    ) {
        guard items.count >= 2, layout.isAvailable(for: items.count) else { return }
        let itemIDs = items.map(\.id)
        compareItemIDs = itemIDs
        compareLayout = layout
        compareSlotItemIDs = MediaComparisonAssignment.initial(
            itemIDs: itemIDs,
            preferredItemID: preferredItemID,
            capacity: layout.capacity
        )
        isComparingImages = true
        resetCropSession()
        resetViewerImageZoom()
    }

    private func clearImageComparisonState() {
        comparePreparationTask?.cancel()
        comparePreparationTask = nil
        isComparingImages = false
        compareItemIDs = []
        compareSlotItemIDs = []
        compareReturnItemID = nil
    }

    private func reconcileImageComparison() {
        guard isComparingImages else { return }
        let currentIDs = selectedItemsInOrder
            .filter { $0.type == .image }
            .map(\.id)
        guard currentIDs.count >= 2 else {
            endImageComparison()
            return
        }

        compareItemIDs = currentIDs
        if !compareLayout.isAvailable(for: currentIDs.count) {
            let items = currentIDs.compactMap { orderedItemByID[$0] }
            compareLayout = MediaCompareLayout.automatic(
                for: items,
                focusedItemID: focusedItemID
            )
        }

        compareSlotItemIDs = MediaComparisonAssignment.resized(
            assignments: compareSlotItemIDs,
            allItemIDs: currentIDs,
            capacity: compareLayout.capacity
        )

        if let compareReturnItemID,
           !visualItems.contains(where: { $0.id == compareReturnItemID }) {
            self.compareReturnItemID = currentIDs.first
            viewerItemID = currentIDs.first
        }
    }

    /// The set of items the viewer's Left/Right navigation walks. For a multi-item
    /// selection, browsing is confined to its visual items; otherwise it spans
    /// every image and video in the folder.
    var viewerPlaylist: [MediaItem] {
        let selectedVisual = visualItems.filter { selectedItemIDs.contains($0.id) }
        return selectedItemIDs.count > 1 && !selectedVisual.isEmpty
            ? selectedVisual
            : visualItems
    }

    /// Open the preview for the current selection. Uses the focused item when it is
    /// an image or video, otherwise the first selected visual item. Audio-only
    /// selections do nothing (audio is not previewable).
    func openPreview() {
        if let focused = focusedItem,
           focused.type != .audio {
            openViewer(focused)
            return
        }
        if let firstVisual = selectedItemsInOrder.first(where: { $0.type != .audio }) {
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
              let item = orderedItemByID[focusedItemID]
        else { return }

        switch item.type {
        case .video:
            if libraryTab == .all {
                openViewer(item)
            } else {
                playingVideoID = (playingVideoID == item.id) ? nil : item.id
            }
        case .audio:
            if libraryTab == .audio, playingAudioID == item.id {
                isAudioPlaying.toggle()
            } else {
                playingAudioID = (playingAudioID == item.id) ? nil : item.id
            }
        case .image:
            break
        }
    }

    // MARK: - Trash

    /// Move the selected items to the Trash, Finder-style: recoverable, not a
    /// permanent delete. Files that succeed are removed from the listing
    /// immediately; the focus moves to the nearest surviving neighbour.
    func moveSelectedItemsToTrash() {
        if isCollectionSelected {
            removeSelectedFromCollection()
            return
        }
        trashSelectedFiles()
    }

    func moveSelectedFilesToTrashExplicitly(clicked item: MediaItem? = nil) {
        if let item { _ = itemsForAction(clicked: item) }
        trashSelectedFiles()
    }

    private func trashSelectedFiles() {
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
        clearImageComparisonState()
        playingVideoID = nil
        playingAudioID = nil
        resetCropSession()
        resetViewerImageZoom()
        viewerItemID = item.id
        focusedItemID = item.id
    }

    func closeViewer() {
        guard !isApplyingCrop else { return }
        clearImageComparisonState()
        resetCropSession()
        viewerItemID = nil
        resetViewerImageZoom()
    }

    func showPreviousInViewer() {
        guard !isCropping, !isComparingImages else { return }
        stepViewer(by: -1)
    }

    func showNextInViewer() {
        guard !isCropping, !isComparingImages else { return }
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
        resetCropSession()
        resetViewerImageZoom()
        self.viewerItemID = playlist[next].id
    }

    private func resetCropSession() {
        isCropping = false
        isApplyingCrop = false
        cropAspect = .free
        cropImageSize = .zero
        cropNormalizedRect = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
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

    private func isFolder(_ id: MediaFolder.ID, under ancestor: MediaFolder.ID) -> Bool {
        id == ancestor || id.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    private func removingFolder(_ folder: MediaFolder, id: MediaFolder.ID) -> MediaFolder? {
        if folder.id == id { return nil }
        var remaining = folder
        remaining.children = folder.children.compactMap { removingFolder($0, id: id) }
        return remaining
    }
}

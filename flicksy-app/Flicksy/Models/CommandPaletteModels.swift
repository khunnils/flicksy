//
//  CommandPaletteModels.swift
//  Flicksy
//

import Foundation

enum CommandPalettePage: Hashable {
    case root
    case manageTags
    case manageCollections
    case selectionTags
    case selectionCollections
    case openWith

    var title: String? {
        switch self {
        case .root: nil
        case .manageTags: "Manage Tags"
        case .manageCollections: "Manage Collections"
        case .selectionTags: "Tags"
        case .selectionCollections: "Add to Collection"
        case .openWith: "Open With"
        }
    }
}

struct CommandPaletteFileLocation: Identifiable, Hashable, Sendable {
    let item: MediaItem
    let source: BrowserSource
    let locationTitle: String
    let locationKind: String

    nonisolated var id: String { "\(item.id)|\(source.commandPaletteID)" }
    nonisolated var physicalPath: String { item.url.deletingLastPathComponent().path(percentEncoded: false) }

    nonisolated func matchRank(for query: String) -> Int? {
        let query = BrowserDestination.normalized(query)
        guard !query.isEmpty else { return nil }
        let name = BrowserDestination.normalized(item.name)
        let location = BrowserDestination.normalized(locationTitle)
        let path = BrowserDestination.normalized(item.url.path(percentEncoded: false))
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if name.contains(query) { return 2 }
        if location.contains(query) || path.contains(query) { return 3 }
        return nil
    }
}

struct CommandPaletteSearchIndex: Sendable {
    let destinations: [BrowserDestination]
    let files: [CommandPaletteFileLocation]
}

/// Centralized visibility rules for contextual commands. Keeping this separate
/// from the view makes mixed-selection behavior deterministic and testable.
struct CommandPaletteSelectionCapabilities: Equatable, Sendable {
    let itemCount: Int
    let canOpenSelection: Bool
    let canCompareImages: Bool
    let canGetInfo: Bool
    let canEditMetaTags: Bool
    let canOrganize: Bool
    let canDuplicate: Bool
    let canRename: Bool
    let canRemoveFromCollection: Bool

    nonisolated init(
        items: [MediaItem],
        isClipboardSelected: Bool,
        isCollectionSelected: Bool
    ) {
        itemCount = items.count
        canOpenSelection = !items.isEmpty
        canCompareImages = items.reduce(into: 0) { count, item in
            if case .image = item.type { count += 1 }
        } >= 2
        canGetInfo = items.count == 1
        canEditMetaTags = !items.isEmpty && items.allSatisfy {
            AudioTagService.canWrite(url: $0.url)
        }
        canOrganize = !items.isEmpty && items.allSatisfy { $0.libraryID != nil }
        canDuplicate = !items.isEmpty && !isClipboardSelected
        canRename = items.count == 1 && !isClipboardSelected
        canRemoveFromCollection = canOrganize && isCollectionSelected
    }
}

extension BrowserSource {
    nonisolated var commandPaletteID: String {
        switch self {
        case .favorites: "favorites"
        case .tag(let id): "tag-\(id)"
        case .collection(let id): "collection-\(id)"
        case .clipboard: "clipboard"
        case .standardFolder(let folder): "standard-\(folder.rawValue)"
        case .folder(let id): "folder-\(id)"
        }
    }
}

//
//  BrowserDestination.swift
//  Flicksy
//

import Foundation

/// A navigable sidebar destination shared by Quick Goto and the command palette.
struct BrowserDestination: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case library = "Library"
        case collection = "Collection"
        case tag = "Tag"
        case folder = "Folder"
    }

    let id: String
    let title: String
    let detail: String?
    let systemImage: String
    let kind: Kind
    let source: BrowserSource

    func matchRank(for query: String) -> Int? {
        let query = Self.normalized(query)
        guard !query.isEmpty else { return 3 }

        let title = Self.normalized(title)
        let detail = Self.normalized(detail ?? "")
        let kind = Self.normalized(kind.rawValue)

        if title == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        if title.contains(query) { return 2 }
        if detail.contains(query) || kind.contains(query) { return 3 }
        return nil
    }

    nonisolated static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension BrowserModel {
    var browserDestinations: [BrowserDestination] {
        var destinations = [
            BrowserDestination(
                id: "library-favorites",
                title: "Favorites",
                detail: "Library",
                systemImage: "star.fill",
                kind: .library,
                source: .favorites
            ),
            BrowserDestination(
                id: "library-clipboard",
                title: "Clipboard",
                detail: "Library",
                systemImage: "clipboard",
                kind: .library,
                source: .clipboard
            )
        ]

        destinations += StandardBrowserFolder.allCases.map { folder in
            BrowserDestination(
                id: "standard-\(folder.rawValue)",
                title: folder.title,
                detail: "Library",
                systemImage: folder.systemImage,
                kind: .library,
                source: .standardFolder(folder)
            )
        }

        destinations += collections.map { collection in
            BrowserDestination(
                id: "collection-\(collection.id)",
                title: collection.name,
                detail: "Collection",
                systemImage: "rectangle.stack.badge.play",
                kind: .collection,
                source: .collection(collection.id)
            )
        }

        destinations += tags.map { tag in
            BrowserDestination(
                id: "tag-\(tag.id)",
                title: tag.name,
                detail: "Tag",
                systemImage: "tag",
                kind: .tag,
                source: .tag(tag.id)
            )
        }

        for root in rootTrees {
            appendBrowserFolders(root, to: &destinations)
        }
        return destinations
    }

    private func appendBrowserFolders(
        _ folder: MediaFolder,
        to destinations: inout [BrowserDestination]
    ) {
        destinations.append(BrowserDestination(
            id: "folder-\(folder.id)",
            title: folder.name,
            detail: folder.url.deletingLastPathComponent().path(percentEncoded: false),
            systemImage: folder.isRoot ? "folder.badge.gearshape" : "folder",
            kind: .folder,
            source: .folder(folder.id)
        ))
        for child in folder.children {
            appendBrowserFolders(child, to: &destinations)
        }
    }
}

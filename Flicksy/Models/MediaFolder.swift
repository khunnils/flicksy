//
//  MediaFolder.swift
//  MediaBrowser
//

import Foundation

/// A node in the smart folder sidebar tree.
///
/// Only folders that directly contain supported media, or that have a descendant
/// which does, are represented here (see `FolderScanner`). Identity is the folder's
/// filesystem path so that `List` selection and `DisclosureGroup` expansion state
/// remain stable across rescans, even though the tree is rebuilt from scratch.
struct MediaFolder: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isRoot: Bool
    var children: [MediaFolder]

    var id: String { url.path }

    /// `nil` when the folder has no media-bearing subfolders, so SwiftUI's
    /// `OutlineGroup`/`List` can render a leaf row without a disclosure chevron.
    var outlineChildren: [MediaFolder]? {
        children.isEmpty ? nil : children
    }

    nonisolated init(url: URL, name: String? = nil, isRoot: Bool, children: [MediaFolder] = []) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isRoot = isRoot
        self.children = children
    }

    static func == (lhs: MediaFolder, rhs: MediaFolder) -> Bool {
        lhs.id == rhs.id && lhs.children == rhs.children
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

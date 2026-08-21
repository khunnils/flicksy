//
//  FolderScanner.swift
//  MediaBrowser
//

import Foundation
import UniformTypeIdentifiers

/// Filesystem scanning for the smart sidebar and the media grid.
///
/// All work is `nonisolated` so it runs off the main actor; callers should invoke
/// it from a background `Task`. The scanner never modifies the filesystem.
enum FolderScanner {
    /// Resource keys fetched in a single pass during directory enumeration so that
    /// classification (`.contentTypeKey`) and cheap metadata (`.fileSizeKey`,
    /// `.contentModificationDateKey`) cost no additional `stat` calls per file.
    nonisolated private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .contentTypeKey,
        .fileSizeKey,
        .contentModificationDateKey,
    ]

    nonisolated private static var resourceKeySet: Set<URLResourceKey> { Set(resourceKeys) }

    // MARK: - Sidebar tree

    /// Build a pruned folder tree for a single root.
    ///
    /// A folder is retained only if it directly contains supported media or has a
    /// descendant that does, matching the spec's "smart" sidebar (folders such as
    /// `Admin` that contain only non-media files disappear). The root node itself
    /// is always returned so the user can see the folder they added, even if empty.
    ///
    /// Declared `nonisolated async` so it executes on the concurrent pool (off the
    /// main actor) while still propagating cancellation from the caller's `Task`.
    nonisolated static func buildTree(for root: URL) async throws -> MediaFolder {
        let children = try prunedChildren(of: root)
        return MediaFolder(url: root, isRoot: true, children: children)
    }

    /// Recursively collect media-bearing subfolders of `directory`.
    nonisolated private static func prunedChildren(of directory: URL) throws -> [MediaFolder] {
        try Task.checkCancellation()

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []

        var subfolders: [MediaFolder] = []

        for url in contents {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: resourceKeySet)

            guard values?.isDirectory == true else { continue }

            let grandchildren = try prunedChildren(of: url)
            let hasDirectMedia = folderHasDirectMedia(url)

            // Keep the subfolder only if it (or something beneath it) has media.
            if hasDirectMedia || !grandchildren.isEmpty {
                subfolders.append(MediaFolder(url: url, isRoot: false, children: grandchildren))
            }
        }

        subfolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return subfolders
    }

    /// Whether a directory directly contains at least one supported media file.
    /// Stops at the first match to avoid enumerating large folders fully.
    nonisolated private static func folderHasDirectMedia(_ directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }

        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
            guard values?.isRegularFile == true, let type = values?.contentType else { continue }
            if MediaType(contentType: type) != nil { return true }
        }
        return false
    }

    // MARK: - Media listing

    /// List the supported media directly inside a folder (non-recursive), sorted
    /// by name using natural ordering. Broken or unsupported files are skipped so a
    /// single bad file never breaks browsing. Runs off the main actor (see
    /// `buildTree`).
    nonisolated static func mediaItems(in directory: URL) async throws -> [MediaItem] {
        try Task.checkCancellation()

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []

        var items: [MediaItem] = []

        for url in contents {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: resourceKeySet),
                  values.isRegularFile == true,
                  let contentType = values.contentType,
                  let type = MediaType(contentType: contentType)
            else { continue }

            items.append(MediaItem(
                url: url,
                type: type,
                name: url.lastPathComponent,
                fileSize: values.fileSize.map(Int64.init),
                modifiedAt: values.contentModificationDate
            ))
        }

        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return items
    }
}

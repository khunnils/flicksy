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
    /// Cheap resource keys fetched during enumeration. Image dimensions are
    /// deliberately excluded: opening every image before first paint makes large
    /// folders appear to hang. Visible thumbnail tasks discover dimensions later.
    nonisolated private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .addedToDirectoryDateKey,
    ]

    nonisolated private static var resourceKeySet: Set<URLResourceKey> { Set(resourceKeys) }
    nonisolated private static let treeResourceKeySet: Set<URLResourceKey> =
        FolderScanPolicy.directoryResourceKeys.union([.isRegularFileKey])

    // MARK: - Sidebar tree

    /// Build a pruned folder tree for a single root.
    ///
    /// A folder is retained only if it directly contains supported media or has a
    /// descendant that does, matching the spec's "smart" sidebar (folders such as
    /// `Admin` that contain only non-media files disappear). The root node itself
    /// is always returned so the user can see the folder they added, even if empty.
    /// Excluded directories are never entered, so a `node_modules` sibling cannot
    /// keep an otherwise empty parent visible.
    ///
    /// Declared `nonisolated async` so it executes on the concurrent pool (off the
    /// main actor) while still propagating cancellation from the caller's `Task`.
    nonisolated static func buildTree(
        for root: URL,
        policy: FolderScanPolicy = .default
    ) async throws -> MediaFolder {
        let children = try scanDirectory(root, policy: policy).children
        return MediaFolder(url: root, isRoot: true, children: children)
    }

    /// Scan each directory once, returning both its visible descendants and
    /// whether anything in the subtree is media-bearing. The previous approach
    /// recursively scanned a child and then enumerated it a second time merely to
    /// answer `folderHasDirectMedia`.
    ///
    /// Descent is gated by `policy` before `contentsOfDirectory` is called on a
    /// child, so expensive trees are never listed.
    nonisolated private static func scanDirectory(
        _ directory: URL,
        policy: FolderScanPolicy
    ) throws -> (children: [MediaFolder], containsMedia: Bool) {
        try Task.checkCancellation()

        let contents = policy.contentsOfDirectory(
            directory,
            includingPropertiesForKeys: Array(treeResourceKeySet)
        )

        var subfolders: [MediaFolder] = []
        var hasDirectMedia = false

        for url in contents {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: treeResourceKeySet)

            if values?.isDirectory == true || policy.excludesDirectoryName(url.lastPathComponent) {
                guard policy.shouldDescend(into: url, values: values) else { continue }
                let result = try scanDirectory(url, policy: policy)
                if result.containsMedia {
                    subfolders.append(MediaFolder(
                        url: url,
                        isRoot: false,
                        children: result.children
                    ))
                }
            } else if !hasDirectMedia,
                      values?.isRegularFile == true,
                      mediaType(for: url) != nil {
                hasDirectMedia = true
            }
        }

        subfolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (subfolders, hasDirectMedia || !subfolders.isEmpty)
    }

    // MARK: - Media listing

    /// Incrementally enumerate supported media directly inside a folder. Batches
    /// let the browser paint quickly instead of waiting for a complete directory
    /// scan. Enumeration and resource reads live in a detached task.
    nonisolated static func mediaItemBatches(
        in directory: URL,
        batchSize: Int = 200
    ) -> AsyncThrowingStream<[MediaItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try enumerateMediaItems(
                        in: directory,
                        batchSize: batchSize,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// `DirectoryEnumerator` is a synchronous sequence. Keeping iteration in a
    /// synchronous helper avoids accidentally binding it to an async executor;
    /// the caller above already places the whole operation in a detached task.
    nonisolated private static func enumerateMediaItems(
        in directory: URL,
        batchSize: Int,
        continuation: AsyncThrowingStream<[MediaItem], Error>.Continuation
    ) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [
                .skipsHiddenFiles,
                .skipsPackageDescendants,
                .skipsSubdirectoryDescendants,
            ]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var batch: [MediaItem] = []
        batch.reserveCapacity(max(1, batchSize))

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard let item = mediaItem(for: url) else { continue }
            batch.append(item)

            if batch.count >= batchSize {
                continuation.yield(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            continuation.yield(batch)
        }
    }

    /// Complete-list convenience retained for callers that do not need partial
    /// results.
    nonisolated static func mediaItems(in directory: URL) async throws -> [MediaItem] {
        var items: [MediaItem] = []
        for try await batch in mediaItemBatches(in: directory) {
            try Task.checkCancellation()
            items.append(contentsOf: batch)
        }
        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return items
    }

    nonisolated private static func mediaItem(for url: URL) -> MediaItem? {
        guard let values = try? url.resourceValues(forKeys: resourceKeySet),
              values.isRegularFile == true,
              let type = mediaType(for: url)
        else { return nil }

        return MediaItem(
            url: url,
            type: type,
            name: url.lastPathComponent,
            fileSize: values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate,
            addedAt: values.addedToDirectoryDate
        )
    }

    /// Filename extensions are available without filesystem I/O and cover the
    /// normal media case. Fall back to the URL content type for extensionless or
    /// unusual files.
    nonisolated private static func mediaType(for url: URL) -> MediaType? {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mediaType = MediaType(contentType: type) {
            return mediaType
        }
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let type = values.contentType
        else {
            return nil
        }
        return MediaType(contentType: type)
    }
}

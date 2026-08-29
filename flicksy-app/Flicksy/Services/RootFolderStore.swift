//
//  RootFolderStore.swift
//  MediaBrowser
//

import AppKit
import Foundation

/// Persists the set of user-authorized root folders across launches.
///
/// Because the app runs in the macOS sandbox, access granted through an
/// `NSOpenPanel` does not automatically survive a relaunch. To re-open a folder
/// silently on the next launch we store a *security-scoped bookmark* (which
/// requires the `com.apple.security.files.bookmarks.app-scope` entitlement) and
/// resolve it back into a URL at startup. Each resolved URL must be wrapped in a
/// balanced `startAccessingSecurityScopedResource()` /
/// `stopAccessingSecurityScopedResource()` pair for the sandbox to allow reads.
@MainActor
final class RootFolderStore {
    private let defaultsKey = "rootFolderBookmarks"

    /// Internal record pairing a live URL with the bookmark it was resolved from,
    /// so we can persist and remove entries and balance security-scoped access.
    private struct Entry {
        let url: URL
        var bookmark: Data
        /// Whether we currently hold a security-scoped access claim on `url`.
        var isAccessing: Bool
    }

    private var entries: [Entry] = []

    /// Currently authorized root folder URLs, in insertion order.
    var urls: [URL] { entries.map(\.url) }

    // MARK: - Restore

    /// Resolve all persisted bookmarks and begin accessing them.
    ///
    /// Returns the human-readable descriptions of any folders that could not be
    /// restored (for example, because they were deleted or moved to a volume that
    /// is no longer mounted) so the caller can surface a re-select prompt.
    @discardableResult
    func restore() -> [String] {
        var failures: [String] = []
        let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        var restored: [Entry] = []
        var needsResave = false

        for bookmark in stored {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                failures.append("A previously added folder could not be found.")
                needsResave = true
                continue
            }

            let didAccess = url.startAccessingSecurityScopedResource()

            // A stale bookmark still resolves but should be re-minted so it keeps
            // working; this requires active security-scoped access to the URL.
            var effectiveBookmark = bookmark
            if isStale {
                if let fresh = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    effectiveBookmark = fresh
                    needsResave = true
                }
            }

            restored.append(Entry(url: url, bookmark: effectiveBookmark, isAccessing: didAccess))
        }

        entries = restored
        if needsResave { persist() }
        return failures
    }

    // MARK: - Add / Remove

    /// Present an `NSOpenPanel` for the user to choose a folder, then persist a
    /// security-scoped bookmark for it. Returns the chosen URL, or `nil` if the
    /// user cancelled or the folder was already added.
    func addFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder to browse for media."

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // Ignore duplicates so the same root cannot be added twice.
        if entries.contains(where: { $0.url == url }) { return nil }

        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return nil
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        entries.append(Entry(url: url, bookmark: bookmark, isAccessing: didAccess))
        persist()
        return url
    }

    /// Remove a root folder, releasing its security-scoped access claim.
    func removeFolder(_ url: URL) {
        guard let index = entries.firstIndex(where: { $0.url == url }) else { return }
        let entry = entries[index]
        if entry.isAccessing {
            entry.url.stopAccessingSecurityScopedResource()
        }
        entries.remove(at: index)
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        UserDefaults.standard.set(entries.map(\.bookmark), forKey: defaultsKey)
    }
}

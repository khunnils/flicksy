//
//  StandardFolderStore.swift
//  MediaBrowser
//

import AppKit
import Foundation

enum StandardBrowserFolder: String, CaseIterable, Hashable {
    case desktop
    case downloads

    var title: String {
        switch self {
        case .desktop: "Desktop"
        case .downloads: "Downloads"
        }
    }

    var systemImage: String {
        switch self {
        case .desktop: "desktopcomputer"
        case .downloads: "arrow.down.circle"
        }
    }

    var url: URL? {
        let directory: FileManager.SearchPathDirectory = switch self {
        case .desktop: .desktopDirectory
        case .downloads: .downloadsDirectory
        }
        // In a sandbox, FileManager may return a container symlink such as
        // `…/Data/Downloads`. Resolve it before enumeration; passing that symlink
        // through as a directory URL can otherwise fail with ENOTDIR.
        return FileManager.default.urls(for: directory, in: .userDomainMask)
            .first?
            .resolvingSymlinksInPath()
    }
}

/// Provides the built-in Desktop and Downloads shortcuts. Downloads has a
/// dedicated sandbox entitlement and opens directly. Desktop gets a one-time
/// Powerbox grant, retained as a security-scoped bookmark for later launches.
@MainActor
final class StandardFolderStore {
    private struct Entry {
        let url: URL
        let isAccessing: Bool
    }

    private var entries: [StandardBrowserFolder: Entry] = [:]

    func restore() {
        // Downloads is covered by its dedicated sandbox entitlement. Older
        // builds saved a bookmark for it, which can become invalid and mask the
        // entitlement-backed URL, so remove that legacy value during migration.
        UserDefaults.standard.removeObject(forKey: bookmarkKey(for: .downloads))
        restore(.desktop)
    }

    private func restore(_ folder: StandardBrowserFolder) {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey(for: folder)) else { return }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey(for: folder))
            return
        }

        let isAccessing = url.startAccessingSecurityScopedResource()
        entries[folder] = Entry(url: url, isAccessing: isAccessing)

        if isStale {
            persistBookmark(for: folder, url: url)
        }
    }

    func url(for folder: StandardBrowserFolder) -> URL? {
        switch folder {
        case .downloads:
            return folder.url
        case .desktop:
            return entries[folder]?.url ?? requestAccess(to: folder)
        }
    }

    var monitoredURLs: [URL] {
        var urls = entries[.desktop].map { [$0.url] } ?? []
        if let downloadsURL = StandardBrowserFolder.downloads.url,
           !urls.contains(downloadsURL) {
            urls.append(downloadsURL)
        }
        return urls
    }

    private func requestAccess(to folder: StandardBrowserFolder) -> URL? {
        guard let suggestedURL = folder.url else { return nil }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggestedURL
        panel.prompt = "Allow Access"
        panel.message = "Allow Flicksy to browse your \(folder.title) folder."

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }

        let isAccessing = selectedURL.startAccessingSecurityScopedResource()
        entries[folder] = Entry(url: selectedURL, isAccessing: isAccessing)
        persistBookmark(for: folder, url: selectedURL)
        return selectedURL
    }

    private func persistBookmark(for folder: StandardBrowserFolder, url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey(for: folder))
    }

    private func bookmarkKey(for folder: StandardBrowserFolder) -> String {
        "standardFolderBookmark.\(folder.rawValue)"
    }
}

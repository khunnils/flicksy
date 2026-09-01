//
//  FolderScanExclusionStore.swift
//  Flicksy
//

import Foundation

/// Persists the subdirectory paths a user hid from the folder browser.
///
/// These sit on top of the built-in `FolderScanPolicy` name list. Hidden folders
/// are skipped before the scanners descend, and they stay hidden across launches.
@MainActor
final class FolderScanExclusionStore {
    private let defaultsKey = "excludedSubdirectoryPaths"
    private let defaults: UserDefaults
    private(set) var excludedPaths: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        excludedPaths = Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    var policy: FolderScanPolicy {
        var policy = FolderScanPolicy.default
        policy.excludedDirectoryPaths = excludedPaths
        return policy
    }

    func exclude(_ url: URL) {
        excludedPaths.insert(FolderScanPolicy.normalizedPath(url))
        persist()
    }

    func hiddenCount(under root: URL) -> Int {
        excludedPaths.count { isPath($0, under: root) }
    }

    /// Remove every hidden path at or under `root`. Returns how many were cleared.
    @discardableResult
    func restoreHidden(under root: URL) -> Int {
        let before = excludedPaths.count
        excludedPaths = excludedPaths.filter { !isPath($0, under: root) }
        if excludedPaths.count != before { persist() }
        return before - excludedPaths.count
    }

    private func isPath(_ path: String, under root: URL) -> Bool {
        let rootPath = FolderScanPolicy.normalizedPath(root)
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func persist() {
        defaults.set(excludedPaths.sorted(), forKey: defaultsKey)
    }
}

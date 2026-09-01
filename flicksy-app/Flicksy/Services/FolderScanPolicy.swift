//
//  FolderScanPolicy.swift
//  Flicksy
//

import Foundation

/// Groups of directory names the recursive scanners skip by default.
///
/// Kept as a public surface so a future settings UI can present, toggle, or
/// replace each group without the scanners knowing about preferences storage.
nonisolated enum FolderScanExclusionGroup: String, Sendable, CaseIterable, Codable {
    case dependencies
    case buildArtifacts
    case caches
    case versionControl
    case ide
    case systemAndMetadata
}

/// Which directories the recursive media scanners are allowed to enter.
///
/// Defaults match a typical user library: skip hidden folders, packages,
/// directory symlinks, and well-known dependency/build/cache trees. Properties
/// are mutable and `Codable` so they can later be persisted as user settings.
nonisolated struct FolderScanPolicy: Sendable, Equatable, Codable {
    /// Skip directories that are hidden (dot-prefixed or the Finder hidden flag).
    /// When true, directory listings also omit hidden files, matching the
    /// existing scanner behavior.
    var skipHiddenDirectories: Bool

    /// Do not follow symbolic links that point at directories. Prevents loops
    /// and indexing the same tree under multiple paths.
    var skipDirectorySymbolicLinks: Bool

    /// Do not recurse into macOS packages and bundles (`.app`, `.framework`,
    /// Photos libraries, Xcode projects, and so on).
    var skipPackages: Bool

    /// Directory names that are never entered, matched case-insensitively.
    /// This is the list a settings UI would let the user edit.
    var excludedDirectoryNames: Set<String>

    /// Specific directory paths the user hid from the folder browser. Matched
    /// after path standardization so the same folder is recognized across scans.
    var excludedDirectoryPaths: Set<String>

    static let `default` = FolderScanPolicy(
        skipHiddenDirectories: true,
        skipDirectorySymbolicLinks: true,
        skipPackages: true,
        excludedDirectoryNames: builtInExcludedDirectoryNames,
        excludedDirectoryPaths: []
    )

    static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Resource keys required to decide whether to descend, prefetched during
    /// listing so the check does not open the child directory.
    static let directoryResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isHiddenKey,
    ]

    static let builtInNamesByGroup: [FolderScanExclusionGroup: Set<String>] = [
        .dependencies: [
            "node_modules",
            "bower_components",
            "jspm_packages",
            "vendor",
            "Pods",
            "Carthage",
            "site-packages",
            "venv",
            ".venv",
            "virtualenv",
            ".virtualenv",
            ".tox",
            ".nox",
            ".bundle",
            ".swiftpm",
            ".pnpm-store",
            ".yarn",
            ".npm",
            ".m2",
            ".gradle",
        ],
        .buildArtifacts: [
            "DerivedData",
            ".build",
            "build",
            "target",
            "cmake-build-debug",
            "cmake-build-release",
            "_build",
            "xcuserdata",
            "Index.noindex",
            "ModuleCache.noindex",
            "CompilationCache.noindex",
            "SDKStatCaches.noindex",
        ],
        .caches: [
            ".cache",
            ".next",
            ".nuxt",
            ".svelte-kit",
            ".turbo",
            ".parcel-cache",
            ".sass-cache",
            ".webpack",
            ".eslintcache",
            "coverage",
            ".nyc_output",
            "__pycache__",
            ".mypy_cache",
            ".pytest_cache",
            ".ruff_cache",
            ".ipynb_checkpoints",
        ],
        .versionControl: [
            ".git",
            ".svn",
            ".hg",
            ".bzr",
            "CVS",
            ".jj",
        ],
        .ide: [
            ".idea",
            ".vscode",
            ".vs",
            ".cursor",
            ".fleet",
            ".settings",
        ],
        .systemAndMetadata: [
            "Library",
            "__MACOSX",
            ".Trash",
            ".Trashes",
            ".Spotlight-V100",
            ".fseventsd",
            ".TemporaryItems",
            ".DocumentRevisions-V100",
            ".MobileBackups",
            ".AppleDB",
            ".AppleDesktop",
            ".AppleDouble",
            ".PKInstallSandboxManager",
            "Network Trash Folder",
            "Temporary Items",
            "$RECYCLE.BIN",
            "System Volume Information",
            "lost+found",
        ],
    ]

    static var builtInExcludedDirectoryNames: Set<String> {
        Set(builtInNamesByGroup.values.flatMap { $0 })
    }

    /// Bundles the system reports as packages, plus common extensions in case
    /// the package bit is missing (for example on a non-HFS/APFS test volume).
    static let packagePathExtensions: Set<String> = [
        "app",
        "appex",
        "framework",
        "xcframework",
        "bundle",
        "plugin",
        "kext",
        "xpc",
        "dsym",
        "playground",
        "xcodeproj",
        "xcworkspace",
        "photoslibrary",
        "photolibrary",
        "imovielibrary",
        "tvlibrary",
        "musiclibrary",
        "localized",
    ]

    var directoryEnumerationOptions: FileManager.DirectoryEnumerationOptions {
        var options: FileManager.DirectoryEnumerationOptions = []
        if skipHiddenDirectories {
            options.insert(.skipsHiddenFiles)
        }
        if skipPackages {
            options.insert(.skipsPackageDescendants)
        }
        return options
    }

    func excludesDirectoryName(_ name: String) -> Bool {
        excludedDirectoryNames.contains {
            $0.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    func excludesDirectoryPath(_ url: URL) -> Bool {
        excludedDirectoryPaths.contains(Self.normalizedPath(url))
    }

    /// Name or path exclusion, decided without opening the directory.
    func excludes(_ url: URL) -> Bool {
        excludesDirectoryName(url.lastPathComponent) || excludesDirectoryPath(url)
    }

    /// Immediate children of `directory`, using the policy's listing options.
    /// Callers must still consult `shouldDescend` before recursing; this helper
    /// never opens an excluded child because it only lists `directory` itself.
    func contentsOfDirectory(
        _ directory: URL,
        includingPropertiesForKeys keys: [URLResourceKey]
    ) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: directoryEnumerationOptions
        )) ?? []
    }

    /// Whether a recursive scanner may enter `url`.
    ///
    /// Name exclusions are evaluated first so a known-expensive folder such as
    /// `node_modules` is rejected without interpreting its contents. The
    /// directory itself is never opened here; callers must skip descent when
    /// this returns `false`.
    func shouldDescend(into url: URL, values: URLResourceValues?) -> Bool {
        if excludes(url) {
            return false
        }

        guard let values else { return true }
        if values.isDirectory != true {
            return false
        }
        if skipDirectorySymbolicLinks, values.isSymbolicLink == true {
            return false
        }
        if skipPackages, isPackage(url, values: values) {
            return false
        }
        if skipHiddenDirectories, values.isHidden == true {
            return false
        }
        return true
    }

    private func isPackage(_ url: URL, values: URLResourceValues) -> Bool {
        if values.isPackage == true { return true }
        return Self.packagePathExtensions.contains(url.pathExtension.lowercased())
    }
}

/// Depth-first walk used by the catalog indexer. The sidebar tree uses the same
/// policy but needs to retain folder structure, so it walks itself.
nonisolated enum FolderScanWalker {
    /// Visit every regular file under `root`. The root is always entered;
    /// excluded, hidden, packaged, and symlinked directories are never listed.
    nonisolated static func forEachRegularFile(
        in root: URL,
        keys: Set<URLResourceKey>,
        policy: FolderScanPolicy = .default,
        visit: (URL, URLResourceValues) throws -> Void
    ) throws {
        let listingKeys = keys.union(FolderScanPolicy.directoryResourceKeys)
        try walk(directory: root, keys: listingKeys, policy: policy, visit: visit)
    }

    nonisolated private static func walk(
        directory: URL,
        keys: Set<URLResourceKey>,
        policy: FolderScanPolicy,
        visit: (URL, URLResourceValues) throws -> Void
    ) throws {
        try Task.checkCancellation()

        let contents = policy.contentsOfDirectory(
            directory,
            includingPropertiesForKeys: Array(keys)
        )

        for url in contents {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: keys)

            if values?.isDirectory == true || policy.excludes(url) {
                if policy.shouldDescend(into: url, values: values) {
                    try walk(directory: url, keys: keys, policy: policy, visit: visit)
                }
                continue
            }

            guard let values else { continue }
            try visit(url, values)
        }
    }
}

//
//  MediaFileMover.swift
//  Flicksy
//

import Foundation

struct MediaFileMoveResult: Sendable {
    let movedNames: [String]
    let conflictingNames: [String]
    let failedNames: [String]
    let unchangedNames: [String]

    var movedCount: Int { movedNames.count }
    var hasFailures: Bool { !conflictingNames.isEmpty || !failedNames.isEmpty }
}

/// Moves real media files without replacing anything already in the destination.
/// The caller performs this off the main actor and refreshes the browser afterward.
enum MediaFileMover {
    nonisolated static func move(_ sourceURLs: [URL], into destinationFolder: URL) -> MediaFileMoveResult {
        let fileManager = FileManager.default
        let destination = destinationFolder.standardizedFileURL
        var seenSources: Set<URL> = []
        var movedNames: [String] = []
        var conflictingNames: [String] = []
        var failedNames: [String] = []
        var unchangedNames: [String] = []

        for sourceURL in sourceURLs {
            let source = sourceURL.standardizedFileURL
            guard seenSources.insert(source).inserted else { continue }

            let name = source.lastPathComponent
            if source.deletingLastPathComponent().standardizedFileURL == destination {
                unchangedNames.append(name)
                continue
            }

            let target = destination.appendingPathComponent(name, isDirectory: false)
            if fileManager.fileExists(atPath: target.path) {
                conflictingNames.append(name)
                continue
            }

            do {
                try fileManager.moveItem(at: source, to: target)
                movedNames.append(name)
            } catch {
                failedNames.append(name)
            }
        }

        return MediaFileMoveResult(
            movedNames: movedNames,
            conflictingNames: conflictingNames,
            failedNames: failedNames,
            unchangedNames: unchangedNames
        )
    }
}

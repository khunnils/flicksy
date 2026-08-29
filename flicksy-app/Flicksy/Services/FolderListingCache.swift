//
//  FolderListingCache.swift
//  Flicksy
//

import CryptoKit
import Foundation

/// A lightweight stale-while-revalidate index for folder contents. It stores no
/// thumbnails or expensive metadata: just enough to paint the previous listing
/// immediately while `FolderScanner` reconciles the directory in the background.
enum FolderListingCache {
    nonisolated private struct Listing: Codable {
        let schemaVersion: Int
        let items: [Record]
    }

    nonisolated private struct Record: Codable {
        let path: String
        let type: String
        let name: String
        let fileSize: Int64?
        let modifiedAt: Date?
        let addedAt: Date?

        init(_ item: MediaItem) {
            path = item.url.path
            switch item.type {
            case .image: type = "image"
            case .video: type = "video"
            case .audio: type = "audio"
            }
            name = item.name
            fileSize = item.fileSize
            modifiedAt = item.modifiedAt
            addedAt = item.addedAt
        }

        var mediaItem: MediaItem? {
            let mediaType: MediaType
            switch type {
            case "image": mediaType = .image
            case "video": mediaType = .video
            case "audio": mediaType = .audio
            default: return nil
            }
            return MediaItem(
                url: URL(fileURLWithPath: path),
                type: mediaType,
                name: name,
                fileSize: fileSize,
                modifiedAt: modifiedAt,
                addedAt: addedAt
            )
        }
    }

    nonisolated private static let schemaVersion = 1

    nonisolated static func load(for directory: URL) -> [MediaItem]? {
        guard let url = cacheURL(for: directory),
              let data = try? Data(contentsOf: url),
              let listing = try? PropertyListDecoder().decode(Listing.self, from: data),
              listing.schemaVersion == schemaVersion
        else { return nil }

        return listing.items.compactMap(\.mediaItem)
    }

    nonisolated static func store(_ items: [MediaItem], for directory: URL) {
        guard let url = cacheURL(for: directory) else { return }
        let listing = Listing(
            schemaVersion: schemaVersion,
            items: items.map(Record.init)
        )
        guard let data = try? PropertyListEncoder().encode(listing) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated private static func cacheURL(for directory: URL) -> URL? {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }

        let root = caches.appending(path: "Flicksy/FolderListings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let path = directory.standardizedFileURL.path
        let key = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return root.appending(path: "\(key).plist", directoryHint: .notDirectory)
    }
}

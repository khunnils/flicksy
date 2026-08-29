//
//  PersistentMediaCache.swift
//  MediaBrowser
//

import AppKit
import CryptoKit
import Foundation
import ImageIO

/// Small, versioned records shared by the thumbnail, waveform, and video preview
/// services. Files live in the system Caches directory, so macOS may purge them
/// and every caller must remain able to regenerate a missing or corrupt entry.
enum PersistentMediaCache {
    nonisolated struct ImageRecord: Codable {
        let imageData: Data
        let pixelWidth: Int?
        let pixelHeight: Int?

        nonisolated init(imageData: Data, pixelWidth: Int?, pixelHeight: Int?) {
            self.imageData = imageData
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    nonisolated struct WaveformRecord: Codable {
        let peaks: [Float]

        nonisolated init(peaks: [Float]) { self.peaks = peaks }
    }

    nonisolated struct StoryboardRecord: Codable {
        let frames: [Data]
        let duration: TimeInterval

        nonisolated init(frames: [Data], duration: TimeInterval) {
            self.frames = frames
            self.duration = duration
        }
    }

    nonisolated private static let schemaVersion = 1
    nonisolated private static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Start one best-effort maintenance pass during model initialization. Cache
    /// failures are invisible because every preview can be regenerated.
    nonisolated static func scheduleMaintenance() {
        Task.detached(priority: .background) {
            pruneIfNeeded()
        }
    }

    /// Includes size and nanosecond modification time so replacing a file at the
    /// same path cannot return stale media from either memory or disk.
    nonisolated static func key(for url: URL, variant: String) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0
        let source = "v\(schemaVersion)|\(url.standardizedFileURL.path)|\(size)|\(modified)|\(variant)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func load<Value: Decodable>(
        _ type: Value.Type,
        namespace: String,
        key: String
    ) -> Value? {
        guard let url = entryURL(namespace: namespace, key: key),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? PropertyListDecoder().decode(type, from: data)
    }

    nonisolated static func store<Value: Encodable>(
        _ value: Value,
        namespace: String,
        key: String
    ) {
        guard let url = entryURL(namespace: namespace, key: key),
              let data = try? PropertyListEncoder().encode(value)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// PNG preserves transparency in still-image thumbnails and avoids another
    /// lossy generation when a cached frame is loaded on a later launch.
    nonisolated static func encodedImage(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Decode immediately on the calling background task rather than deferring
    /// decompression until SwiftUI draws on the main thread.
    nonisolated static func decodedImage(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated private static func entryURL(namespace: String, key: String) -> URL? {
        guard let root = cacheRoot() else { return nil }
        let directory = root.appending(path: namespace, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(key).cache", directoryHint: .notDirectory)
    }

    nonisolated private static func cacheRoot() -> URL? {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let root = caches.appending(path: "Flicksy/MediaCache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Keep the cache bounded. Oldest generated entries are discarded first;
    /// removal is safe because every entry is derived and reproducible.
    nonisolated private static func pruneIfNeeded() {
        guard let root = cacheRoot(),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return }

        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            ]), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }

        guard total > maximumBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > maximumBytes {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }
}

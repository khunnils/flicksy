//
//  ClipboardHistoryStore.swift
//  MediaBrowser
//

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A pasteboard image captured synchronously by `BrowserModel` before the system
/// clipboard changes again. File URLs are copied into Flicksy's container
/// immediately by `ClipboardHistoryStore`.
nonisolated enum ClipboardImageCandidate: Sendable {
    case file(URL, originalName: String)
    case data(Data, preferredExtension: String, originalName: String)
}

/// Persistent, app-owned clipboard image history. The store intentionally keeps
/// ordinary image files so the existing thumbnail, preview, drag, and copy paths
/// can treat clipboard entries exactly like media from a folder.
actor ClipboardHistoryStore {
    nonisolated static let maximumItemCount = 100
    nonisolated static let maximumBytes: Int64 = 1024 * 1024 * 1024

    nonisolated private struct Record: Codable, Sendable {
        let contentHash: String
        let fileName: String
        var displayName: String
        var capturedAt: Date
        let byteCount: Int64
        let width: Int?
        let height: Int?
    }

    private var records: [Record] = []
    private var didLoad = false
    private let directoryOverride: URL?

    init(directoryURL: URL? = nil) {
        directoryOverride = directoryURL
    }

    func items() -> [MediaItem] {
        loadIfNeeded()
        return makeItems()
    }

    /// Import all images represented by one pasteboard change. Re-copying the
    /// same pixels moves the existing entry to the front instead of duplicating
    /// its storage.
    func importImages(_ candidates: [ClipboardImageCandidate], capturedAt: Date = .now) throws -> [MediaItem] {
        loadIfNeeded()
        guard !candidates.isEmpty else { return makeItems() }

        let directory = try historyDirectory()
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()

            guard let materialized = try? materialize(candidate),
                  let dimensions = imageDimensions(in: materialized.data)
            else { continue }

            let hash = SHA256.hash(data: materialized.data)
                .map { String(format: "%02x", $0) }
                .joined()

            if let existing = records.firstIndex(where: { $0.contentHash == hash }) {
                records[existing].capturedAt = capturedAt
                if !materialized.originalName.isEmpty {
                    records[existing].displayName = materialized.originalName
                }
                continue
            }

            let fileName = "\(hash).\(materialized.fileExtension)"
            let destination = directory.appending(path: fileName, directoryHint: .notDirectory)
            try materialized.data.write(to: destination, options: .atomic)

            let fallbackName = Self.fallbackName(
                capturedAt: capturedAt,
                index: index,
                fileExtension: materialized.fileExtension
            )
            records.append(Record(
                contentHash: hash,
                fileName: fileName,
                displayName: materialized.originalName.isEmpty ? fallbackName : materialized.originalName,
                capturedAt: capturedAt,
                byteCount: Int64(materialized.data.count),
                width: dimensions.width,
                height: dimensions.height
            ))
        }

        enforceLimits(in: directory)
        try persist()
        return makeItems()
    }

    /// Files may already have been moved to the Trash through the normal browser
    /// action; this only removes their now-stale manifest records.
    func removeReferences(to urls: [URL]) throws -> [MediaItem] {
        loadIfNeeded()
        let names = Set(urls.map(\.lastPathComponent))
        records.removeAll { names.contains($0.fileName) }
        try persist()
        return makeItems()
    }

    func clear() throws -> [MediaItem] {
        loadIfNeeded()
        let directory = try historyDirectory()
        for record in records {
            try? FileManager.default.removeItem(
                at: directory.appending(path: record.fileName, directoryHint: .notDirectory)
            )
        }
        records = []
        try persist()
        return []
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        guard let manifest = try? manifestURL(),
              let data = try? Data(contentsOf: manifest),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else { return }

        let directory = try? historyDirectory()
        records = decoded.filter { record in
            guard let directory else { return false }
            return FileManager.default.fileExists(
                atPath: directory.appending(path: record.fileName).path
            )
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: manifestURL(), options: .atomic)
    }

    private func makeItems() -> [MediaItem] {
        guard let directory = try? historyDirectory() else { return [] }
        return records
            .sorted { $0.capturedAt > $1.capturedAt }
            .map { record in
                MediaItem(
                    url: directory.appending(path: record.fileName, directoryHint: .notDirectory),
                    type: .image,
                    name: record.displayName,
                    width: record.width,
                    height: record.height,
                    fileSize: record.byteCount,
                    modifiedAt: record.capturedAt
                )
            }
    }

    private func enforceLimits(in directory: URL) {
        records.sort { $0.capturedAt > $1.capturedAt }

        var retained: [Record] = []
        var totalBytes: Int64 = 0
        var removed: [Record] = []

        for record in records {
            let fits = retained.count < Self.maximumItemCount
                && totalBytes + record.byteCount <= Self.maximumBytes
            if fits {
                retained.append(record)
                totalBytes += record.byteCount
            } else {
                removed.append(record)
            }
        }

        records = retained
        for record in removed {
            try? FileManager.default.removeItem(
                at: directory.appending(path: record.fileName, directoryHint: .notDirectory)
            )
        }
    }

    private func historyDirectory() throws -> URL {
        if let directoryOverride {
            try FileManager.default.createDirectory(
                at: directoryOverride,
                withIntermediateDirectories: true
            )
            return directoryOverride
        }

        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appending(path: "Flicksy/Clipboard", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func manifestURL() throws -> URL {
        try historyDirectory()
            .appending(path: "history.json", directoryHint: .notDirectory)
    }

    // MARK: - Import

    private func materialize(
        _ candidate: ClipboardImageCandidate
    ) throws -> (data: Data, fileExtension: String, originalName: String)? {
        switch candidate {
        case .file(let url, let originalName):
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard imageDimensions(in: data) != nil else { return nil }
            return (
                data,
                normalizedExtension(url.pathExtension, imageData: data),
                originalName
            )

        case .data(let data, let preferredExtension, let originalName):
            guard imageDimensions(in: data) != nil else { return nil }
            return (
                data,
                normalizedExtension(preferredExtension, imageData: data),
                originalName
            )
        }
    }

    private func normalizedExtension(_ candidate: String, imageData: Data) -> String {
        let cleaned = candidate
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        if let type = UTType(filenameExtension: cleaned), type.conforms(to: .image), !cleaned.isEmpty {
            return cleaned
        }

        if let source = CGImageSourceCreateWithData(imageData as CFData, nil),
           let identifier = CGImageSourceGetType(source) as String?,
           let preferred = UTType(identifier)?.preferredFilenameExtension {
            return preferred
        }
        return "png"
    }

    /// Returns display-oriented dimensions, including EXIF rotation.
    private func imageDimensions(in data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0
        else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    nonisolated private static func fallbackName(
        capturedAt: Date,
        index: Int,
        fileExtension: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let suffix = index == 0 ? "" : " \(index + 1)"
        return "Clipboard \(formatter.string(from: capturedAt))\(suffix).\(fileExtension)"
    }
}

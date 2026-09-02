//
//  MediaItem.swift
//  MediaBrowser
//

import Foundation
import UniformTypeIdentifiers

/// A single media file discovered on disk.
///
/// Cheap-to-obtain fields (`type`, `name`, `fileSize`, `modifiedAt`, `addedAt`) are populated
/// during the folder scan from resource values that come "for free" with the
/// directory enumeration. Expensive fields (`duration`, pixel dimensions) are
/// filled in lazily by later milestones and remain `nil` until then.
struct MediaItem: Identifiable, Hashable, Sendable {
    /// Identity is the file's path so that selection and playback state stay
    /// stable across rescans (which rebuild the item list from scratch), matching
    /// how `MediaFolder` keys on its path.
    nonisolated var id: String { libraryID?.uuidString ?? url.path }

    /// Stable app-owned identity for media inside an added root. Transient
    /// Desktop, Downloads, and Clipboard items deliberately remain path keyed.
    let libraryID: UUID?

    /// Creator-organization state hydrated from the catalog for root-backed
    /// media. Transient sources leave these at their empty defaults.
    var isFavorite: Bool
    var tags: [LibraryTag]

    /// Changes when a file is replaced or rewritten in place while keeping the
    /// same path. Async view tasks use this to discard stale previews/metadata.
    nonisolated var contentVersion: String {
        let size = fileSize ?? -1
        let modified = modifiedAt?.timeIntervalSinceReferenceDate.bitPattern ?? 0
        return "\(url.path)|\(size)|\(modified)"
    }

    let url: URL
    let type: MediaType
    let name: String

    var duration: TimeInterval?
    var width: Int?
    var height: Int?
    var bitRate: Int?
    var sampleRate: Double?
    var channelCount: Int?
    var fileSize: Int64?
    var modifiedAt: Date?
    var addedAt: Date?

    nonisolated init(
        libraryID: UUID? = nil,
        isFavorite: Bool = false,
        url: URL,
        type: MediaType,
        name: String,
        tags: [LibraryTag] = [],
        duration: TimeInterval? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bitRate: Int? = nil,
        sampleRate: Double? = nil,
        channelCount: Int? = nil,
        fileSize: Int64? = nil,
        modifiedAt: Date? = nil,
        addedAt: Date? = nil
    ) {
        self.libraryID = libraryID
        self.isFavorite = isFavorite
        self.url = url
        self.type = type
        self.name = name
        self.tags = tags
        self.duration = duration
        self.width = width
        self.height = height
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.addedAt = addedAt
    }

    /// Matches the Kind column in the All and Audio lists: the system’s
    /// localized type name, or the extension when that is all we have.
    nonisolated var kindDescription: String {
        let fileExtension = url.pathExtension
        guard !fileExtension.isEmpty else {
            switch type {
            case .image: return "Image"
            case .video: return "Video"
            case .audio: return "Audio"
            }
        }
        return UTType(filenameExtension: fileExtension)?.localizedDescription
            ?? fileExtension.uppercased()
    }
}

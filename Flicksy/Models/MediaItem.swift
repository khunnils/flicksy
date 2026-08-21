//
//  MediaItem.swift
//  MediaBrowser
//

import Foundation

/// A single media file discovered on disk.
///
/// Cheap-to-obtain fields (`type`, `name`, `fileSize`, `modifiedAt`) are populated
/// during the folder scan from resource values that come "for free" with the
/// directory enumeration. Expensive fields (`duration`, pixel dimensions) are
/// filled in lazily by later milestones and remain `nil` until then.
struct MediaItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let type: MediaType
    let name: String

    var duration: TimeInterval?
    var width: Int?
    var height: Int?
    var fileSize: Int64?
    var modifiedAt: Date?

    nonisolated init(
        id: UUID = UUID(),
        url: URL,
        type: MediaType,
        name: String,
        duration: TimeInterval? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fileSize: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.type = type
        self.name = name
        self.duration = duration
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }
}

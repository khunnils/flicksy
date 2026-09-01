//
//  LibraryModels.swift
//  Flicksy
//

import AppKit
import Foundation
import SwiftUI

/// A small, fixed palette keeps tag colors recognizable and accessible in both
/// appearances. The color decorates dots/chips only; media itself is never tinted.
enum LibraryTagColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case gray, red, orange, yellow, green, blue, purple, pink

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .gray: .gray
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }

    /// Menu pickers treat SF Symbols as templates, wiping palette color. A drawn,
    /// non-template swatch keeps each option's hue visible in the Color menu.
    var menuSwatch: Image {
        Image(nsImage: Self.makeMenuSwatch(color))
    }

    private static func makeMenuSwatch(_ color: Color) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct LibraryTag: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var color: LibraryTagColor
    var itemCount: Int
}

struct MediaCollection: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var itemCount: Int
}

struct MissingCollectionItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let assetID: UUID
    let name: String
    let lastKnownPath: String
}

enum LibraryQuery: Sendable {
    case all
    case favorites
    case tag(UUID)
    case collection(UUID)
}

struct LibraryQueryResult: Sendable {
    var items: [MediaItem]
    var missingItems: [MissingCollectionItem] = []
}

/// One available library asset plus every collection that can display it.
/// Favorite and tag membership already live on the hydrated `MediaItem`.
struct LibrarySearchRecord: Sendable {
    let item: MediaItem
    let collections: [MediaCollection]
}

/// Shared sheet routing for organization editors opened from the sidebar,
/// toolbar, or command palette.
enum OrganizationEditorRequest: Identifiable {
    case newCollection(addingSelection: Bool)
    case editCollection(MediaCollection)
    case newTag(applyingSelection: Bool)
    case editTag(LibraryTag)

    var id: String {
        switch self {
        case .newCollection(let applies): "new-collection-\(applies)"
        case .editCollection(let collection): "collection-\(collection.id)"
        case .newTag(let applies): "new-tag-\(applies)"
        case .editTag(let tag): "tag-\(tag.id)"
        }
    }
}

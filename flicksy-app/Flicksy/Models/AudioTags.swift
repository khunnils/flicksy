//
//  AudioTags.swift
//  Flicksy
//

import Foundation

/// Song metadata matching the Apple Music Get Info Details fields.
nonisolated struct AudioTags: Equatable, Sendable {
    var title: String = ""
    var artist: String = ""
    var albumArtist: String = ""
    var album: String = ""
    var grouping: String = ""
    var composer: String = ""
    var comments: String = ""
    var genre: String = ""
    var year: String = ""
    var trackNumber: String = ""
    var trackCount: String = ""
    var discNumber: String = ""
    var discCount: String = ""
    var bpm: String = ""
    var isCompilation: Bool = false

    static let empty = AudioTags()

    var normalized: AudioTags {
        AudioTags(
            title: title.trimmed,
            artist: artist.trimmed,
            albumArtist: albumArtist.trimmed,
            album: album.trimmed,
            grouping: grouping.trimmed,
            composer: composer.trimmed,
            comments: comments.trimmingCharacters(in: .whitespacesAndNewlines),
            genre: genre.trimmed,
            year: year.trimmed,
            trackNumber: trackNumber.trimmed,
            trackCount: trackCount.trimmed,
            discNumber: discNumber.trimmed,
            discCount: discCount.trimmed,
            bpm: bpm.trimmed,
            isCompilation: isCompilation
        )
    }

    /// Overwrites only `fields` from `overlay`, leaving every other value as-is.
    func applying(_ overlay: AudioTags, fields: Set<AudioTagField>) -> AudioTags {
        var result = self
        for field in fields {
            if let path = field.stringKeyPath {
                result[keyPath: path] = overlay[keyPath: path]
            } else if field == .isCompilation {
                result.isCompilation = overlay.isCompilation
            }
        }
        return result
    }

    /// Shared values across `tags`. Differing fields are empty and listed in `mixed`.
    static func consensus(of tags: [AudioTags]) -> (values: AudioTags, mixed: Set<AudioTagField>) {
        guard let first = tags.first?.normalized else { return (.empty, []) }
        guard tags.count > 1 else { return (first, []) }

        let normalized = tags.map(\.normalized)
        var values = first
        var mixed: Set<AudioTagField> = []

        for field in AudioTagField.allCases {
            if let path = field.stringKeyPath {
                let unique = Set(normalized.map { $0[keyPath: path] })
                if unique.count > 1 {
                    mixed.insert(field)
                    values[keyPath: path] = ""
                }
            } else if field == .isCompilation {
                if Set(normalized.map(\.isCompilation)).count > 1 {
                    mixed.insert(.isCompilation)
                    values.isCompilation = false
                }
            }
        }
        return (values, mixed)
    }

    /// Fills blank fields from `other` without overwriting values already set.
    func fillingEmpty(from other: AudioTags) -> AudioTags {
        AudioTags(
            title: title.or(other.title),
            artist: artist.or(other.artist),
            albumArtist: albumArtist.or(other.albumArtist),
            album: album.or(other.album),
            grouping: grouping.or(other.grouping),
            composer: composer.or(other.composer),
            comments: comments.or(other.comments),
            genre: genre.or(other.genre),
            year: year.or(other.year),
            trackNumber: trackNumber.or(other.trackNumber),
            trackCount: trackCount.or(other.trackCount),
            discNumber: discNumber.or(other.discNumber),
            discCount: discCount.or(other.discCount),
            bpm: bpm.or(other.bpm),
            isCompilation: isCompilation || other.isCompilation
        )
    }
}

/// One Details field. Used so a multi-file edit can write only the values the
/// user actually changed, leaving mixed per-file data (names, track numbers)
/// untouched.
nonisolated enum AudioTagField: Hashable, CaseIterable, Sendable {
    case title, artist, albumArtist, album, grouping, composer, comments
    case genre, year, trackNumber, trackCount, discNumber, discCount, bpm
    case isCompilation

    var stringKeyPath: WritableKeyPath<AudioTags, String>? {
        switch self {
        case .title: \.title
        case .artist: \.artist
        case .albumArtist: \.albumArtist
        case .album: \.album
        case .grouping: \.grouping
        case .composer: \.composer
        case .comments: \.comments
        case .genre: \.genre
        case .year: \.year
        case .trackNumber: \.trackNumber
        case .trackCount: \.trackCount
        case .discNumber: \.discNumber
        case .discCount: \.discCount
        case .bpm: \.bpm
        case .isCompilation: nil
        }
    }
}

nonisolated enum AudioTagIndex {
    /// `"3/12"` → `("3", "12")`. A bare number is the index with an empty count.
    static func split(_ value: String) -> (number: String, count: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }
        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            return (String(parts[0]).trimmed, String(parts[1]).trimmed)
        }
        return (trimmed, "")
    }

    /// Encodes track/disc as `n`, `n/m`, or `/m`. Returns `nil` when both are empty.
    static func joined(number: String, count: String) -> String? {
        let number = number.trimmed
        let count = count.trimmed
        if number.isEmpty && count.isEmpty { return nil }
        if count.isEmpty { return number }
        return "\(number)/\(count)"
    }
}

nonisolated private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func or(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

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

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func or(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

//
//  AudioTagService.swift
//  Flicksy
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Reads and writes the Apple Music Details tags on audio files.
enum AudioTagService {
    enum TagError: LocalizedError {
        case unsupportedFormat
        case replaceFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                "Tags can’t be edited for this audio format."
            case .replaceFailed:
                "The original file could not be replaced. If this folder was added before write access was enabled, remove and re-add it."
            }
        }
    }

    nonisolated static func canWrite(url: URL) -> Bool {
        isMP3(url)
    }

    nonisolated static func load(from url: URL) async -> AudioTags {
        let fromAsset = await loadFromAsset(url)
        if isMP3(url),
           let data = try? Data(contentsOf: url),
           let parsed = ID3Tag.parse(data) {
            return parsed.tags.fillingEmpty(from: fromAsset)
        }
        return fromAsset
    }

    nonisolated static func write(_ tags: AudioTags, to url: URL) async throws {
        guard isMP3(url) else { throw TagError.unsupportedFormat }
        do {
            try ID3Tag.write(tags.normalized, to: url)
        } catch {
            throw TagError.replaceFailed
        }
    }

    nonisolated private static func isMP3(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "mp3" { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .mp3) ?? false
    }

    // MARK: - Read

    nonisolated private static func loadFromAsset(_ url: URL) async -> AudioTags {
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.metadata)) ?? []
        var tags = AudioTags.empty

        tags.title = string(from: items, [
            .iTunesMetadataSongName, .id3MetadataTitleDescription, .commonIdentifierTitle,
        ])
        tags.artist = string(from: items, [
            .iTunesMetadataArtist, .id3MetadataLeadPerformer, .commonIdentifierArtist,
        ])
        tags.albumArtist = string(from: items, [
            .iTunesMetadataAlbumArtist, .id3MetadataBand,
        ])
        tags.album = string(from: items, [
            .iTunesMetadataAlbum, .id3MetadataAlbumTitle, .commonIdentifierAlbumName,
        ])
        tags.grouping = string(from: items, [
            .iTunesMetadataGrouping, .id3MetadataContentGroupDescription,
        ])
        tags.composer = string(from: items, [
            .iTunesMetadataComposer, .id3MetadataComposer, .commonIdentifierCreator,
        ])
        tags.comments = string(from: items, [
            .iTunesMetadataUserComment, .id3MetadataComments, .commonIdentifierDescription,
        ])
        tags.genre = cleanedGenre(string(from: items, [
            .iTunesMetadataUserGenre, .id3MetadataContentType, .commonIdentifierType,
            .iTunesMetadataPredefinedGenre,
        ]))
        tags.year = year(from: items)
        let track = indexPair(from: items, [
            .iTunesMetadataTrackNumber, .id3MetadataTrackNumber,
        ])
        tags.trackNumber = track.number
        tags.trackCount = track.count
        let disc = indexPair(from: items, [
            .iTunesMetadataDiscNumber, .id3MetadataPartOfASet,
        ])
        tags.discNumber = disc.number
        tags.discCount = disc.count
        tags.bpm = string(from: items, [
            .iTunesMetadataBeatsPerMin, .id3MetadataBeatsPerMinute,
        ])
        tags.isCompilation = compilation(from: items)
        return tags
    }

    nonisolated private static func string(
        from items: [AVMetadataItem],
        _ identifiers: [AVMetadataIdentifier]
    ) -> String {
        for identifier in identifiers {
            guard let item = items.first(where: { $0.identifier == identifier }) else { continue }
            if let string = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !string.isEmpty {
                return string
            }
            if let number = item.numberValue {
                let string = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !string.isEmpty, string != "0" { return string }
            }
        }
        return ""
    }

    nonisolated private static func year(from items: [AVMetadataItem]) -> String {
        let identifiers: [AVMetadataIdentifier] = [
            .iTunesMetadataReleaseDate,
            .id3MetadataRecordingTime,
            .id3MetadataYear,
        ]
        for identifier in identifiers {
            guard let item = items.first(where: { $0.identifier == identifier }) else { continue }
            if let string = item.stringValue {
                let digits = string.prefix { $0.isNumber }
                if digits.count >= 4 { return String(digits.prefix(4)) }
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let date = item.dateValue {
                return String(Calendar.current.component(.year, from: date))
            }
            if let number = item.numberValue, number.intValue >= 1000 {
                return String(number.intValue)
            }
        }
        return ""
    }

    nonisolated private static func indexPair(
        from items: [AVMetadataItem],
        _ identifiers: [AVMetadataIdentifier]
    ) -> (number: String, count: String) {
        for identifier in identifiers {
            guard let item = items.first(where: { $0.identifier == identifier }) else { continue }
            if let data = item.dataValue, data.count >= 6 {
                let bytes = [UInt8](data)
                let number = Int(bytes[2]) << 8 | Int(bytes[3])
                let count = Int(bytes[4]) << 8 | Int(bytes[5])
                return (
                    number > 0 ? String(number) : "",
                    count > 0 ? String(count) : ""
                )
            }
            if let string = item.stringValue, !string.isEmpty {
                return AudioTagIndex.split(string)
            }
            if let number = item.numberValue, number.intValue > 0 {
                return (String(number.intValue), "")
            }
        }
        return ("", "")
    }

    nonisolated private static func compilation(from items: [AVMetadataItem]) -> Bool {
        guard let item = items.first(where: { $0.identifier == .iTunesMetadataDiscCompilation }) else {
            return false
        }
        if let number = item.numberValue { return number.intValue != 0 }
        if let string = item.stringValue {
            return string == "1" || string.lowercased() == "true"
        }
        if let data = item.dataValue, let first = data.first { return first != 0 }
        return false
    }

    nonisolated private static func cleanedGenre(_ raw: String) -> String {
        guard raw.hasPrefix("("), let close = raw.firstIndex(of: ")") else { return raw }
        let name = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? raw : name
    }
}

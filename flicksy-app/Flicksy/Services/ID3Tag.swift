//
//  ID3Tag.swift
//  Flicksy
//

import Foundation

/// ID3v2.3 read/write for MP3 files. Unknown frames (artwork, lyrics, and so on)
/// are preserved so a Details edit does not strip the rest of the tag.
enum ID3Tag {
    struct Frame: Equatable, Sendable {
        var id: String
        var flags: UInt16
        var data: Data
    }

    struct Payload: Equatable, Sendable {
        var tags: AudioTags
        var preserved: [Frame]
        var audioStart: Int
        var stripTrailer: Int
    }

    private static let managedIDs: Set<String> = [
        "TIT1", "TIT2", "TALB", "TPE1", "TPE2", "TCOM", "COMM", "TCON",
        "TYER", "TDRC", "TDAT", "TRCK", "TPOS", "TBPM", "TCMP",
        "TT1", "TT2", "TAL", "TP1", "TP2", "TCM", "COM", "TCO", "TYE", "TRK", "TPA", "TBP",
    ]

    nonisolated static func parse(_ data: Data) -> Payload? {
        guard data.count >= 10 else {
            return Payload(tags: .empty, preserved: [], audioStart: 0, stripTrailer: id3v1Length(in: data))
        }

        if data.starts(with: Array("ID3".utf8)) {
            return parseTaggedFile(data)
        }

        return Payload(tags: .empty, preserved: [], audioStart: 0, stripTrailer: id3v1Length(in: data))
    }

    nonisolated static func encode(_ tags: AudioTags, preserving frames: [Frame] = []) -> Data {
        var body = Data()
        func appendText(_ id: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            body.append(frame(id: id, data: encodeText(trimmed)))
        }

        let normalized = tags.normalized
        appendText("TIT2", normalized.title)
        appendText("TPE1", normalized.artist)
        appendText("TPE2", normalized.albumArtist)
        appendText("TALB", normalized.album)
        appendText("TIT1", normalized.grouping)
        appendText("TCOM", normalized.composer)
        appendText("TCON", normalized.genre)
        appendText("TYER", normalized.year)
        if let track = AudioTagIndex.joined(number: normalized.trackNumber, count: normalized.trackCount) {
            appendText("TRCK", track)
        }
        if let disc = AudioTagIndex.joined(number: normalized.discNumber, count: normalized.discCount) {
            appendText("TPOS", disc)
        }
        appendText("TBPM", normalized.bpm)
        if !normalized.comments.isEmpty {
            body.append(frame(id: "COMM", data: encodeComment(normalized.comments)))
        }
        if normalized.isCompilation {
            appendText("TCMP", "1")
        }

        for preserved in frames where !managedIDs.contains(preserved.id) {
            body.append(frame(id: preserved.id, flags: preserved.flags, data: preserved.data))
        }

        var header = Data("ID3".utf8)
        header.append(contentsOf: [3, 0, 0])
        header.append(contentsOf: synchsafe(body.count))
        header.append(body)
        return header
    }

    /// Replaces a leading ID3v2 tag (and a trailing ID3v1 tag) with a new v2.3 tag.
    nonisolated static func write(_ tags: AudioTags, to url: URL) throws {
        let data = try Data(contentsOf: url)
        let parsed = parse(data) ?? Payload(tags: .empty, preserved: [], audioStart: 0, stripTrailer: 0)
        let audioEnd = data.count - parsed.stripTrailer
        let audio = audioEnd > parsed.audioStart
            ? data.subdata(in: parsed.audioStart..<audioEnd)
            : Data()
        let encoded = encode(tags, preserving: parsed.preserved)
        try (encoded + audio).write(to: url, options: .atomic)
    }

    // MARK: - Parse

    nonisolated private static func parseTaggedFile(_ data: Data) -> Payload {
        let version = data[3]
        let flags = data[5]
        let tagSize = unsynchsafe(data[6], data[7], data[8], data[9])
        var offset = 10
        if flags & 0x40 != 0 {
            // Extended header. v2.3 stores its size as a 4-byte integer;
            // v2.4 stores a synchsafe size that includes the size field.
            guard offset + 4 <= data.count else {
                return Payload(tags: .empty, preserved: [], audioStart: 0, stripTrailer: id3v1Length(in: data))
            }
            if version >= 4 {
                offset += unsynchsafe(data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
            } else {
                let extended = int32(data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
                offset += 4 + extended
            }
        }

        let tagEnd = min(data.count, 10 + tagSize)
        var tags = AudioTags.empty
        var preserved: [Frame] = []

        while offset + 10 <= tagEnd {
            if data[offset] == 0 { break }
            let id: String
            let frameSize: Int
            let frameFlags: UInt16
            let headerSize: Int

            if version == 2 {
                id = String(bytes: data[offset..<(offset + 3)], encoding: .ascii) ?? ""
                frameSize = int24(data[offset + 3], data[offset + 4], data[offset + 5])
                frameFlags = 0
                headerSize = 6
            } else {
                id = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
                if version >= 4 {
                    frameSize = unsynchsafe(data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7])
                } else {
                    frameSize = int32(data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7])
                }
                frameFlags = UInt16(data[offset + 8]) << 8 | UInt16(data[offset + 9])
                headerSize = 10
            }

            guard id.allSatisfy({ $0.isLetter || $0.isNumber }), frameSize >= 0,
                  offset + headerSize + frameSize <= data.count
            else { break }

            let frameData = data.subdata(in: (offset + headerSize)..<(offset + headerSize + frameSize))
            offset += headerSize + frameSize

            let canonical = canonicalize(id)
            if managedIDs.contains(id) || managedIDs.contains(canonical) {
                apply(canonical, data: frameData, to: &tags)
            } else if version != 2 {
                preserved.append(Frame(id: id, flags: frameFlags, data: frameData))
            }
        }

        var audioStart = 10 + tagSize
        if flags & 0x10 != 0 { audioStart += 10 }
        audioStart = min(audioStart, data.count)
        return Payload(
            tags: tags,
            preserved: preserved,
            audioStart: audioStart,
            stripTrailer: id3v1Length(in: data)
        )
    }

    nonisolated private static func apply(_ id: String, data: Data, to tags: inout AudioTags) {
        switch id {
        case "TIT2": tags.title = tags.title.or(decodeText(data))
        case "TPE1": tags.artist = tags.artist.or(decodeText(data))
        case "TPE2": tags.albumArtist = tags.albumArtist.or(decodeText(data))
        case "TALB": tags.album = tags.album.or(decodeText(data))
        case "TIT1": tags.grouping = tags.grouping.or(decodeText(data))
        case "TCOM": tags.composer = tags.composer.or(decodeText(data))
        case "TCON": tags.genre = tags.genre.or(cleanedGenre(decodeText(data)))
        case "TYER", "TDRC":
            if tags.year.isEmpty { tags.year = year(from: decodeText(data)) }
        case "TRCK":
            if tags.trackNumber.isEmpty && tags.trackCount.isEmpty {
                let pair = AudioTagIndex.split(decodeText(data))
                tags.trackNumber = pair.number
                tags.trackCount = pair.count
            }
        case "TPOS":
            if tags.discNumber.isEmpty && tags.discCount.isEmpty {
                let pair = AudioTagIndex.split(decodeText(data))
                tags.discNumber = pair.number
                tags.discCount = pair.count
            }
        case "TBPM": tags.bpm = tags.bpm.or(decodeText(data))
        case "COMM": tags.comments = tags.comments.or(decodeComment(data))
        case "TCMP":
            let value = decodeText(data)
            if value == "1" || value.lowercased() == "true" { tags.isCompilation = true }
        default:
            break
        }
    }

    nonisolated private static func canonicalize(_ id: String) -> String {
        switch id {
        case "TT2": "TIT2"
        case "TP1": "TPE1"
        case "TP2": "TPE2"
        case "TAL": "TALB"
        case "TT1": "TIT1"
        case "TCM": "TCOM"
        case "COM": "COMM"
        case "TCO": "TCON"
        case "TYE": "TYER"
        case "TRK": "TRCK"
        case "TPA": "TPOS"
        case "TBP": "TBPM"
        default: id
        }
    }

    // MARK: - Text

    nonisolated private static func encodeText(_ string: String) -> Data {
        var data = Data([1])
        data.append(utf16LE(string, terminated: true))
        return data
    }

    nonisolated private static func encodeComment(_ string: String) -> Data {
        var data = Data([1])
        data.append(contentsOf: Array("eng".utf8))
        data.append(utf16LE("", terminated: true))
        data.append(utf16LE(string, terminated: true))
        return data
    }

    nonisolated private static func utf16LE(_ string: String, terminated: Bool) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in string.utf16 {
            var little = unit.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }
        if terminated {
            data.append(contentsOf: [0x00, 0x00])
        }
        return data
    }

    nonisolated private static func decodeText(_ data: Data) -> String {
        guard let encoding = data.first else { return "" }
        return decodeString(data.dropFirst(), encoding: encoding)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func decodeComment(_ data: Data) -> String {
        guard data.count > 4, let encoding = data.first else { return "" }
        var rest = data.dropFirst(4) // encoding + language
        _ = readTerminatedString(from: &rest, encoding: encoding)
        return decodeString(rest, encoding: encoding)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func decodeString(_ data: Data.SubSequence, encoding: UInt8) -> String {
        var bytes = Data(data)
        switch encoding {
        case 1, 2:
            while bytes.count >= 2, bytes.suffix(2) == Data([0, 0]) {
                bytes.removeLast(2)
            }
            let parsed = encoding == 1
                ? String(data: bytes, encoding: .utf16)
                : String(data: bytes, encoding: .utf16BigEndian)
            return parsed ?? ""
        case 3:
            while bytes.last == 0 { bytes.removeLast() }
            return String(data: bytes, encoding: .utf8) ?? ""
        default:
            while bytes.last == 0 { bytes.removeLast() }
            return String(data: bytes, encoding: .isoLatin1) ?? ""
        }
    }

    nonisolated private static func readTerminatedString(from data: inout Data.SubSequence, encoding: UInt8) -> String {
        switch encoding {
        case 1, 2:
            var index = data.startIndex
            while index + 1 < data.endIndex {
                if data[index] == 0 && data[index + 1] == 0 {
                    let value = decodeString(data[data.startIndex..<index], encoding: encoding)
                    data = data[(index + 2)...]
                    return value
                }
                index += 2
            }
            let value = decodeString(data, encoding: encoding)
            data = data[data.endIndex...]
            return value
        default:
            if let null = data.firstIndex(of: 0) {
                let value = decodeString(data[data.startIndex..<null], encoding: encoding)
                data = data[data.index(after: null)...]
                return value
            }
            let value = decodeString(data, encoding: encoding)
            data = data[data.endIndex...]
            return value
        }
    }

    nonisolated private static func cleanedGenre(_ raw: String) -> String {
        guard raw.hasPrefix("("), let close = raw.firstIndex(of: ")") else { return raw }
        let name = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? raw : name
    }

    nonisolated private static func year(from raw: String) -> String {
        let digits = raw.prefix { $0.isNumber }
        return digits.count >= 4 ? String(digits.prefix(4)) : raw
    }

    // MARK: - Binary

    nonisolated private static func frame(id: String, flags: UInt16 = 0, data: Data) -> Data {
        var frame = Data(id.utf8)
        let size = UInt32(data.count).bigEndian
        var sizeBE = size
        frame.append(Data(bytes: &sizeBE, count: 4))
        frame.append(contentsOf: [UInt8(flags >> 8), UInt8(flags & 0xFF)])
        frame.append(data)
        return frame
    }

    nonisolated private static func synchsafe(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F),
        ]
    }

    nonisolated private static func unsynchsafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        (Int(a) << 21) | (Int(b) << 14) | (Int(c) << 7) | Int(d)
    }

    nonisolated private static func int32(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        (Int(a) << 24) | (Int(b) << 16) | (Int(c) << 8) | Int(d)
    }

    nonisolated private static func int24(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int {
        (Int(a) << 16) | (Int(b) << 8) | Int(c)
    }

    nonisolated private static func id3v1Length(in data: Data) -> Int {
        guard data.count >= 128 else { return 0 }
        let trailer = data.subdata(in: (data.count - 128)..<data.count)
        return trailer.starts(with: Array("TAG".utf8)) ? 128 : 0
    }
}

private extension String {
    func or(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

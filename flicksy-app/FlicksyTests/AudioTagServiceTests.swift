//
//  AudioTagServiceTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

final class AudioTagServiceTests: XCTestCase {
    private var scratchURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in scratchURLs {
            try? FileManager.default.removeItem(at: url)
        }
        scratchURLs.removeAll()
    }

    func testID3RoundTripsAppleMusicDetailsTags() {
        let tags = sampleTags()
        let encoded = ID3Tag.encode(tags)
        let parsed = ID3Tag.parse(encoded)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.tags, tags)
        XCTAssertTrue(encoded.starts(with: Array("ID3".utf8)))
    }

    func testID3WritePreservesAudioBytesAndUnknownFrames() throws {
        let url = uniqueURL(extension: "mp3")
        let artwork = ID3Tag.Frame(id: "APIC", flags: 0, data: Data([0x00, 0x69, 0x6D, 0x61, 0x67, 0x65]))
        let original = sampleTags()
        var file = ID3Tag.encode(original, preserving: [artwork])
        file.append(contentsOf: Array("FAKEAUDIO".utf8))
        try file.write(to: url)

        var updated = original
        updated.title = "Retitled"
        updated.album = "New Album"
        updated.isCompilation = false
        try ID3Tag.write(updated, to: url)

        let rewritten = try Data(contentsOf: url)
        XCTAssertTrue(rewritten.starts(with: Array("ID3".utf8)))
        XCTAssertEqual(rewritten.suffix(9), Data("FAKEAUDIO".utf8))

        let parsed = ID3Tag.parse(rewritten)
        XCTAssertEqual(parsed?.tags.title, "Retitled")
        XCTAssertEqual(parsed?.tags.album, "New Album")
        XCTAssertEqual(parsed?.tags.artist, original.artist)
        XCTAssertFalse(parsed?.tags.isCompilation ?? true)
        XCTAssertEqual(parsed?.preserved, [artwork])
    }

    func testID3WriteStripsTrailingID3v1() throws {
        let url = uniqueURL(extension: "mp3")
        var file = ID3Tag.encode(sampleTags())
        file.append(contentsOf: Array("AUDIO".utf8))
        var v1 = Data(repeating: 0, count: 128)
        v1.replaceSubrange(0..<3, with: Array("TAG".utf8))
        file.append(v1)
        try file.write(to: url)

        try ID3Tag.write(sampleTags(), to: url)
        let rewritten = try Data(contentsOf: url)
        XCTAssertEqual(rewritten.suffix(5), Data("AUDIO".utf8))
        XCTAssertFalse(rewritten.suffix(128).starts(with: Array("TAG".utf8)))
    }

    func testCanWriteMP3Only() {
        XCTAssertTrue(AudioTagService.canWrite(url: URL(fileURLWithPath: "/tmp/song.mp3")))
        XCTAssertFalse(AudioTagService.canWrite(url: URL(fileURLWithPath: "/tmp/song.m4a")))
        XCTAssertFalse(AudioTagService.canWrite(url: URL(fileURLWithPath: "/tmp/song.wav")))
        XCTAssertFalse(AudioTagService.canWrite(url: URL(fileURLWithPath: "/tmp/song.flac")))
    }

    func testWriteRejectsNonMP3() async {
        let m4a = uniqueURL(extension: "m4a")
        do {
            try await AudioTagService.write(sampleTags(), to: m4a)
            XCTFail("Expected unsupportedFormat")
        } catch AudioTagService.TagError.unsupportedFormat {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMP3LoadUsesWrittenID3() async throws {
        let url = uniqueURL(extension: "mp3")
        var file = ID3Tag.encode(sampleTags())
        file.append(contentsOf: Array("AUDIO".utf8))
        try file.write(to: url)

        let loaded = await AudioTagService.load(from: url)
        XCTAssertEqual(loaded, sampleTags())
    }

    func testSlashIndexParsing() {
        XCTAssertEqual(AudioTagIndex.split("3/12").number, "3")
        XCTAssertEqual(AudioTagIndex.split("3/12").count, "12")
        XCTAssertEqual(AudioTagIndex.joined(number: "3", count: "12"), "3/12")
        XCTAssertEqual(AudioTagIndex.joined(number: "3", count: ""), "3")
        XCTAssertNil(AudioTagIndex.joined(number: "", count: ""))
    }

    func testConsensusMarksDifferingFieldsMixedAndKeepsSharedValues() {
        var a = sampleTags()
        var b = sampleTags()
        b.title = "Dawn Drive"
        b.trackNumber = "5"
        b.artist = "The Couriers"
        a.album = "Interstate"
        b.album = "Interstate"

        let consensus = AudioTags.consensus(of: [a, b])
        XCTAssertEqual(consensus.values.album, "Interstate")
        XCTAssertEqual(consensus.values.artist, "The Couriers")
        XCTAssertTrue(consensus.mixed.contains(.title))
        XCTAssertTrue(consensus.mixed.contains(.trackNumber))
        XCTAssertFalse(consensus.mixed.contains(.album))
        XCTAssertFalse(consensus.mixed.contains(.artist))
        XCTAssertEqual(consensus.values.title, "")
        XCTAssertEqual(consensus.values.trackNumber, "")
    }

    func testApplyingOverlayWritesOnlyRequestedFields() {
        let original = sampleTags()
        var overlay = AudioTags.empty
        overlay.album = "Night Roads"
        overlay.artist = "The Couriers"
        overlay.title = "Should Not Apply"

        let merged = original.applying(overlay, fields: [.album, .artist])
        XCTAssertEqual(merged.album, "Night Roads")
        XCTAssertEqual(merged.artist, "The Couriers")
        XCTAssertEqual(merged.title, original.title)
        XCTAssertEqual(merged.trackNumber, original.trackNumber)
        XCTAssertEqual(merged.isCompilation, original.isCompilation)
    }

    func testBatchAlbumWriteLeavesPerFileTitles() throws {
        let first = uniqueURL(extension: "mp3")
        let second = uniqueURL(extension: "mp3")
        var tagsA = sampleTags()
        tagsA.title = "Track A"
        tagsA.album = "Old"
        var tagsB = sampleTags()
        tagsB.title = "Track B"
        tagsB.album = "Old"
        try writeTagged(tagsA, to: first)
        try writeTagged(tagsB, to: second)

        var overlay = AudioTags.empty
        overlay.album = "New Album"
        try ID3Tag.write(tagsA.applying(overlay, fields: [.album]), to: first)
        try ID3Tag.write(tagsB.applying(overlay, fields: [.album]), to: second)

        let parsedA = ID3Tag.parse(try Data(contentsOf: first))?.tags
        let parsedB = ID3Tag.parse(try Data(contentsOf: second))?.tags
        XCTAssertEqual(parsedA?.title, "Track A")
        XCTAssertEqual(parsedB?.title, "Track B")
        XCTAssertEqual(parsedA?.album, "New Album")
        XCTAssertEqual(parsedB?.album, "New Album")
        XCTAssertEqual(parsedA?.artist, sampleTags().artist)
    }

    // MARK: - Fixtures

    private func sampleTags() -> AudioTags {
        AudioTags(
            title: "Night Drive",
            artist: "The Couriers",
            albumArtist: "The Couriers",
            album: "Interstate",
            grouping: "Side A",
            composer: "Lena Hart",
            comments: "Take 4",
            genre: "Synthpop",
            year: "2019",
            trackNumber: "4",
            trackCount: "11",
            discNumber: "1",
            discCount: "2",
            bpm: "118",
            isCompilation: true
        )
    }

    private func uniqueURL(extension fileExtension: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyTags-\(UUID().uuidString).\(fileExtension)")
        scratchURLs.append(url)
        return url
    }

    private func writeTagged(_ tags: AudioTags, to url: URL) throws {
        var file = ID3Tag.encode(tags)
        file.append(contentsOf: Array("AUDIO".utf8))
        try file.write(to: url)
    }
}

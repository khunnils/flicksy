//
//  AudioTrimmerTests.swift
//  FlicksyTests
//

import AVFoundation
import XCTest
@testable import Flicksy

final class AudioTrimmerTests: XCTestCase {
    private var audioURL: URL!

    override func setUpWithError() throws {
        audioURL = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyTrim-\(UUID().uuidString).wav")
        try writeSineWAV(to: audioURL, duration: 1)
    }

    override func tearDownWithError() throws {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
    }

    func testCanTrimWAVButNotMP3() {
        XCTAssertTrue(AudioTrimmer.canTrim(url: audioURL))
        let mp3 = URL(fileURLWithPath: "/tmp/example.mp3")
        XCTAssertFalse(AudioTrimmer.canTrim(url: mp3))
    }

    func testTrimKeepsSelectedRange() async throws {
        let trimmed = try await AudioTrimmer.trim(url: audioURL, start: 0.25, end: 0.75)
        XCTAssertEqual(trimmed, 0.5, accuracy: 0.05)

        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(duration.isNumeric)
        XCTAssertEqual(duration.seconds, 0.5, accuracy: 0.08)
    }

    func testTrimRejectsTinyRange() async {
        do {
            _ = try await AudioTrimmer.trim(url: audioURL, start: 0.1, end: 0.12)
            XCTFail("Expected invalidRange")
        } catch AudioTrimmer.TrimError.invalidRange {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func writeSineWAV(to url: URL, duration: TimeInterval, sampleRate: Int = 44_100) throws {
        let sampleCount = Int((duration * Double(sampleRate)).rounded())
        var samples = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            let value = sin(2 * Double.pi * 440 * time) * 0.4
            var sample = Int16((value * Double(Int16.max)).rounded()).littleEndian
            samples.append(Data(bytes: &sample, count: 2))
        }

        var data = Data()
        func appendASCII(_ string: String) {
            data.append(contentsOf: string.utf8)
        }
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + samples.count))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(samples.count))
        data.append(samples)
        try data.write(to: url)
    }
}

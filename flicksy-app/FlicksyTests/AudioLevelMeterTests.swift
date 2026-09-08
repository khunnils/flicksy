import AVFoundation
import MediaToolbox
import XCTest
@testable import Flicksy

@MainActor
final class AudioLevelMeterTests: XCTestCase {
    func testHalfScaleSineAtSupportedSampleRatesAndLayouts() throws {
        for rate in [44_100.0, 48_000, 96_000] {
            for interleaved in [false, true] {
                let meter = AudioLevelMeter()
                try feed(meter, rate: rate, channels: 2, interleaved: interleaved) { frame, channel in
                    sin(2 * .pi * 1000 * Double(frame) / rate) * (channel == 0 ? 0.5 : 0.25)
                }
                meter.update(at: 0.3)
                XCTAssertEqual(meter.levels[0].heldPeakDB, -6.0206, accuracy: 0.02)
                XCTAssertEqual(meter.levels[0].rmsDB, -9.0309, accuracy: 0.02)
                XCTAssertEqual(meter.levels[1].heldPeakDB, -12.0412, accuracy: 0.02)
                XCTAssertEqual(meter.levels[1].rmsDB, -15.0515, accuracy: 0.02)
            }
        }
    }

    func testSilenceAndIndependentMultichannelLevels() throws {
        let meter = AudioLevelMeter()
        try feed(meter, channels: 6) { _, channel in channel == 0 ? 0 : Double(channel) / 10 }
        meter.update(at: 0.3)
        XCTAssertEqual(meter.levels.count, 6)
        XCTAssertEqual(meter.levels[0].rmsDB, -.infinity)
        XCTAssertEqual(meter.levels[0].peakDB, -.infinity)
        for channel in 1..<6 {
            XCTAssertEqual(meter.levels[channel].rmsDB, 20 * log10(Double(channel) / 10), accuracy: 0.001)
        }
    }

    func testImpulseIsPreservedBetweenUIUpdatesAndPeakHeld() throws {
        let meter = AudioLevelMeter()
        try feed(meter) { frame, _ in frame == 100 ? 1 : 0 }
        meter.update(at: 0.05)
        XCTAssertEqual(meter.levels[0].heldPeakDB, 0)
        XCTAssertTrue(meter.levels[0].fullScale)
        meter.update(at: 0.3)
        XCTAssertEqual(meter.levels[0].heldPeakDB, 0)
        meter.update(at: 1.1)
        XCTAssertEqual(meter.levels[0].heldPeakDB, -.infinity)
        meter.clearFullScale()
        XCTAssertFalse(meter.levels[0].fullScale)
    }

    func testDecodeAheadAndResetDiscardStaleMeasurements() throws {
        let meter = AudioLevelMeter()
        try feed(meter) { frame, _ in frame < 4800 ? 0.25 : 0.75 }
        meter.update(at: 0.05)
        XCTAssertEqual(meter.levels[0].heldPeakDB, 20 * log10(0.25), accuracy: 0.001)
        meter.reset()
        meter.update(at: 0.3)
        XCTAssertEqual(meter.levels[0].rmsDB, -.infinity)
        XCTAssertEqual(meter.levels[0].heldPeakDB, -.infinity)
    }

    func testFloatOverFullScaleIsNotClamped() throws {
        let meter = AudioLevelMeter()
        try feed(meter) { _, _ in 1.25 }
        meter.update(at: 0.3)
        XCTAssertEqual(meter.levels[0].heldPeakDB, 20 * log10(1.25), accuracy: 0.001)
        XCTAssertTrue(meter.levels[0].fullScale)
    }

    func testRMSUsesOnlyLatest300Milliseconds() throws {
        let meter = AudioLevelMeter()
        try feed(meter, seconds: 0.6) { frame, _ in frame < 14_400 ? 0.5 : 0.25 }
        meter.update(at: 0.3)
        XCTAssertEqual(meter.levels[0].rmsDB, 20 * log10(0.5), accuracy: 0.001)
        meter.update(at: 0.6)
        XCTAssertEqual(meter.levels[0].rmsDB, 20 * log10(0.25), accuracy: 0.001)
    }

    func testPacked24BitBothEndiannessesAndSignedMinimum() {
        for big in [false, true] {
            let meter = AudioLevelMeter()
            let format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | (big ? kAudioFormatFlagIsBigEndian : 0),
                mBytesPerPacket: 3, mFramesPerPacket: 1, mBytesPerFrame: 3, mChannelsPerFrame: 1,
                mBitsPerChannel: 24, mReserved: 0)
            meter.storage.prepare(format)
            var bytes = Array(repeating: UInt8(0), count: 1440)
            for index in 0..<480 { bytes[index * 3 + (big ? 0 : 2)] = 0x80 }
            bytes.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                meter.storage.process(&list, frames: 480, start: 0, discontinuity: false)
            }
            meter.update(at: 0.01)
            XCTAssertEqual(meter.levels[0].rmsDB, 0)
            XCTAssertEqual(meter.levels[0].heldPeakDB, 0)
        }
    }

    func testUnsupportedLayoutAndNonFinitePCMDoNotInventLevels() throws {
        let meter = AudioLevelMeter()
        try feed(meter) { _, _ in .nan }
        meter.update(at: 0.3)
        XCTAssertEqual(meter.availability, .unavailable)
    }

    func testAVPlayerTapMeasuresDecodedSamplesBeforeListeningVolume() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meter-integration-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        for frame in 0..<96_000 {
            let sine = Float(sin(2 * Double.pi * 1000 * Double(frame) / 48_000))
            buffer.floatChannelData![0][frame] = sine * 0.5
            buffer.floatChannelData![1][frame] = sine * 0.25
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let meter = AudioLevelMeter()
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = try XCTUnwrap(meter.makeTap(sourceChannels: 2))
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        let item = AVPlayerItem(asset: asset)
        item.audioMix = mix
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            let time = player.currentTime().seconds
            meter.update(at: time)
            if time >= 0.4 && meter.levels.count == 2 && meter.levels[0].rmsDB.isFinite { break }
        }
        XCTAssertEqual(meter.availability, .available)
        guard meter.levels.count == 2 else { return XCTFail("AVPlayer did not deliver stereo meter samples") }
        XCTAssertEqual(meter.levels[0].heldPeakDB, -6.0206, accuracy: 0.05)
        XCTAssertEqual(meter.levels[0].rmsDB, -9.0309, accuracy: 0.05)
        XCTAssertEqual(meter.levels[1].rmsDB, -15.0515, accuracy: 0.05)
        player.pause()
        meter.reset()
        XCTAssertEqual(meter.levels[0].rmsDB, -.infinity)
    }

    private func feed(_ meter: AudioLevelMeter, rate: Double = 48_000, channels: AVAudioChannelCount = 1,
                      interleaved: Bool = false, seconds: Double = 0.3,
                      value: (Int, Int) -> Double) throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: channels == 6 ? kAudioChannelLayoutTag_MPEG_5_1_A : (channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono)))
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: rate, interleaved: interleaved, channelLayout: layout))
        let count = AVAudioFrameCount(rate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for frame in 0..<Int(count) {
            for channel in 0..<Int(channels) {
                let target = buffers[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
                target[interleaved ? frame * Int(channels) + channel : frame] = Float(value(frame, channel))
            }
        }
        meter.storage.prepare(format.streamDescription.pointee)
        meter.storage.process(buffer.mutableAudioBufferList, frames: Int(count), start: 0, discontinuity: false)
        meter.storage.finish()
    }
}

import AVFoundation
import MediaToolbox
import Observation
import Synchronization

struct AudioChannelLevel: Equatable {
    var peakDB: Double = -.infinity
    var rmsDB: Double = -.infinity
    var heldPeakDB: Double = -.infinity
    var fullScale = false
}

/// A single producer (audio callback), single consumer (main actor) queue. All
/// storage is allocated before playback; the callback only touches raw buffers
/// and lock-free atomic indices. Samples are passed through without modification.
nonisolated final class AudioMeterTapStorage: @unchecked Sendable {
    static let maxChannels = 32
    static let capacity = 2048
    let writeIndex = Atomic<Int>(0)
    let readIndex = Atomic<Int>(0)
    let epoch = Atomic<Int>(0)
    let channelCount = Atomic<Int>(0)
    let supported = Atomic<Bool>(false)
    private let values: UnsafeMutablePointer<Double>
    private let peaks: UnsafeMutablePointer<Double>
    private let squares: UnsafeMutablePointer<Double>
    private var format = AudioStreamBasicDescription()
    private var count = 0
    private var binFrames = 1
    private var localEpoch = -1
    private var binStart = 0.0
    private var nextTime = 0.0
    private static let stride = 4 + maxChannels * 2

    init() {
        values = .allocate(capacity: Self.capacity * Self.stride)
        values.initialize(repeating: 0, count: Self.capacity * Self.stride)
        peaks = .allocate(capacity: Self.maxChannels)
        peaks.initialize(repeating: 0, count: Self.maxChannels)
        squares = .allocate(capacity: Self.maxChannels)
        squares.initialize(repeating: 0, count: Self.maxChannels)
    }
    deinit { values.deallocate(); peaks.deallocate(); squares.deallocate() }

    func prepare(_ asbd: AudioStreamBasicDescription) {
        format = asbd
        let channels = Int(asbd.mChannelsPerFrame)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let separate = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytes = Int(asbd.mBytesPerFrame) / max(1, separate ? 1 : channels)
        let valid = bytes > 0 && bytes <= 8 && Int(asbd.mBitsPerChannel) <= bytes * 8
            && asbd.mFormatID == kAudioFormatLinearPCM && asbd.mSampleRate > 0
            && channels > 0 && channels <= Self.maxChannels
            && (isFloat ? [32, 64].contains(asbd.mBitsPerChannel)
                : asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
                    && [8, 16, 24, 32].contains(asbd.mBitsPerChannel))
        binFrames = max(1, Int((asbd.mSampleRate * 0.01).rounded()))
        channelCount.store(channels, ordering: .releasing)
        supported.store(valid, ordering: .releasing)
        resetAccumulator()
    }

    private func resetAccumulator() {
        count = 0
        for channel in 0..<Self.maxChannels { peaks[channel] = 0; squares[channel] = 0 }
    }

    /// Accepts the tap's actual PCM layout, including packed 24-bit and padded
    /// integers. This method does not retain any source buffer pointers.
    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: Double, discontinuity: Bool) {
        guard supported.load(ordering: .acquiring), start.isFinite else { return }
        let generation = epoch.load(ordering: .acquiring)
        if generation != localEpoch || discontinuity || abs(start - nextTime) > 0.002 {
            resetAccumulator()
            localEpoch = generation
        }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let channels = Int(format.mChannelsPerFrame)
        let separate = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerSample = Int(format.mBytesPerFrame) / (separate ? 1 : channels)
        guard bytesPerSample > 0, buffers.count >= (separate ? channels : 1) else { return }
        for frame in 0..<frames {
            if count == 0 { binStart = start + Double(frame) / format.mSampleRate }
            for channel in 0..<channels {
                let buffer = buffers[separate ? channel : 0]
                let offset = frame * Int(format.mBytesPerFrame) + (separate ? 0 : channel * bytesPerSample)
                guard let data = buffer.mData, offset + bytesPerSample <= Int(buffer.mDataByteSize) else {
                    supported.store(false, ordering: .releasing); return
                }
                let value = sample(data.advanced(by: offset), bytes: bytesPerSample)
                guard value.isFinite else { supported.store(false, ordering: .releasing); return }
                peaks[channel] = max(peaks[channel], abs(value))
                squares[channel] += value * value
            }
            count += 1
            if count == binFrames {
                publish(channels: channels)
                resetAccumulator()
            }
        }
        nextTime = start + Double(frames) / format.mSampleRate
    }

    func finish() {
        if count > 0 { publish(channels: Int(format.mChannelsPerFrame)); resetAccumulator() }
    }

    private func sample(_ pointer: UnsafeRawPointer, bytes: Int) -> Double {
        let big = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            if format.mBitsPerChannel == 32 {
                let raw = pointer.loadUnaligned(as: UInt32.self)
                return Double(Float(bitPattern: big ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw)))
            }
            let raw = pointer.loadUnaligned(as: UInt64.self)
            return Double(bitPattern: big ? UInt64(bigEndian: raw) : UInt64(littleEndian: raw))
        }
        var raw: UInt64 = 0
        for index in 0..<bytes {
            let shift = (big ? bytes - 1 - index : index) * 8
            raw |= UInt64(pointer.load(fromByteOffset: index, as: UInt8.self)) << shift
        }
        let bits = Int(format.mBitsPerChannel)
        if format.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0 { raw >>= bytes * 8 - bits }
        let shift = 64 - bits
        let signed = Int64(bitPattern: raw << shift) >> shift
        return Double(signed) / Double(UInt64(1) << (bits - 1))
    }

    private func publish(channels: Int) {
        let write = writeIndex.load(ordering: .relaxed)
        let next = (write + 1) % Self.capacity
        guard next != readIndex.load(ordering: .acquiring) else { return }
        let record = values.advanced(by: write * Self.stride)
        record[0] = binStart
        record[1] = Double(count) / format.mSampleRate
        record[2] = Double(localEpoch)
        record[3] = Double(channels)
        for channel in 0..<channels {
            record[4 + channel * 2] = peaks[channel]
            record[5 + channel * 2] = squares[channel] / Double(count)
        }
        writeIndex.store(next, ordering: .releasing)
    }

    struct Measurement {
        let start: Double
        let duration: Double
        let peaks: [Double]
        let powers: [Double]
        var end: Double { start + duration }
    }

    /// Allocates only on the consumer/main actor. Decode-ahead measurements stay
    /// queued until their asset timestamps reach the playback clock.
    func take(through time: Double) -> [Measurement] {
        var result: [Measurement] = []
        var read = readIndex.load(ordering: .relaxed)
        let generation = epoch.load(ordering: .acquiring)
        while read != writeIndex.load(ordering: .acquiring) {
            let record = values.advanced(by: read * Self.stride)
            if Int(record[2]) == generation {
                if record[0] + record[1] > time + 0.01 { break }
                let channels = Int(record[3])
                result.append(Measurement(start: record[0], duration: record[1],
                    peaks: (0..<channels).map { record[4 + $0 * 2] },
                    powers: (0..<channels).map { record[5 + $0 * 2] }))
            }
            read = (read + 1) % Self.capacity
            readIndex.store(read, ordering: .releasing)
        }
        return result
    }

    func invalidate() { _ = epoch.wrappingAdd(1, ordering: .acquiringAndReleasing) }
}

@Observable @MainActor
final class AudioLevelMeter {
    enum Availability { case loading, available, unavailable }
    private(set) var availability: Availability = .loading
    private(set) var levels: [AudioChannelLevel] = []
    private(set) var sourceChannels = 0
    private(set) var channelLabels: [String] = []
    @ObservationIgnored let storage = AudioMeterTapStorage()
    @ObservationIgnored private var history: [AudioMeterTapStorage.Measurement] = []
    @ObservationIgnored private var holdUntil: [Double] = []
    @ObservationIgnored private var lastTime = 0.0
    var isDownmixed: Bool { sourceChannels > 0 && !levels.isEmpty && sourceChannels != levels.count }

    func makeTap(sourceChannels: Int, labels: [String] = []) -> MTAudioProcessingTap? {
        self.sourceChannels = sourceChannels
        channelLabels = labels
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(storage).toOpaque(),
            init: { _, info, output in output.pointee = info },
            finalize: { tap in Unmanaged<AudioMeterTapStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<AudioMeterTapStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            }, unprepare: { _ in },
            process: { tap, frames, _, buffers, provided, flags in
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, &range, provided)
                guard status == noErr else { provided.pointee = 0; return }
                let storage = Unmanaged<AudioMeterTapStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                storage.process(buffers, frames: provided.pointee, start: range.start.seconds,
                    discontinuity: flags.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0)
                if flags.pointee & kMTAudioProcessingTapFlag_EndOfStream != 0 { storage.finish() }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr,
              let tap else {
            Unmanaged<AudioMeterTapStorage>.fromOpaque(callbacks.clientInfo!).release()
            availability = .unavailable
            return nil
        }
        return tap
    }

    func markUnavailable() { availability = .unavailable }
    func label(for channel: Int) -> String {
        if levels.count == 1 { return "Mono" }
        if levels.count == 2 { return channel == 0 ? "L" : "R" }
        if channelLabels.count == levels.count { return channelLabels[channel] }
        return "Ch \(channel + 1)"
    }

    func update(at time: Double) {
        let count = storage.channelCount.load(ordering: .acquiring)
        guard count > 0 else { return }
        guard storage.supported.load(ordering: .acquiring) else { availability = .unavailable; return }
        availability = .available
        if levels.count != count {
            levels = Array(repeating: AudioChannelLevel(), count: count)
            holdUntil = Array(repeating: 0, count: count)
            history = []
        }
        let fresh = storage.take(through: time)
        history.append(contentsOf: fresh)
        history.removeAll { $0.end <= time - 0.3 || $0.start > time + 0.01 }
        let delta = max(0, time - lastTime)
        for channel in 0..<count {
            let amplitude = fresh.map { $0.peaks[channel] }.max() ?? 0
            let peak = Self.decibels(amplitude)
            var power = 0.0, duration = 0.0
            for bin in history {
                let overlap = max(0, min(bin.end, time) - max(bin.start, time - 0.3))
                power += bin.powers[channel] * overlap
                duration += overlap
            }
            levels[channel].rmsDB = duration > 0 ? Self.decibels(sqrt(power / duration)) : -.infinity
            levels[channel].peakDB = max(peak, levels[channel].peakDB - 24 * delta)
            if peak >= levels[channel].heldPeakDB || time >= holdUntil[channel] {
                levels[channel].heldPeakDB = peak
                holdUntil[channel] = time + 1
            }
            levels[channel].fullScale = levels[channel].fullScale || amplitude >= 1
        }
        lastTime = time
    }

    func reset(discardPending: Bool = true) {
        if discardPending { storage.invalidate() }
        history = []
        levels = levels.map { _ in AudioChannelLevel() }
        holdUntil = levels.map { _ in 0 }
        lastTime = 0
    }
    func clearFullScale() { for index in levels.indices { levels[index].fullScale = false } }
    static func decibels(_ amplitude: Double) -> Double { amplitude > 0 ? 20 * log10(amplitude) : -.infinity }
}

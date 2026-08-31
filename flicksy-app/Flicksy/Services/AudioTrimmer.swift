//
//  AudioTrimmer.swift
//  Flicksy
//

import AudioToolbox
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Trims an on-disk audio file and atomically replaces the original.
enum AudioTrimmer {
    enum TrimError: LocalizedError {
        case unreadable
        case invalidRange
        case unsupportedFormat
        case exportFailed
        case replaceFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: "This audio file could not be opened for editing."
            case .invalidRange: "The selected range is too short to trim."
            case .unsupportedFormat: "This audio format cannot be trimmed in place."
            case .exportFailed: "The trimmed audio could not be saved in this format."
            case .replaceFailed: "The original file could not be replaced. If this folder was added before write access was enabled, remove and re-add it."
            }
        }
    }

    /// Formats AVFoundation can write back to the same path without changing
    /// the container. MP3 and similar compressed types are excluded.
    nonisolated static func canTrim(url: URL) -> Bool {
        writableFileType(for: url) != nil
    }

    /// Keeps `start..<end` seconds and overwrites `url`. Returns the new duration.
    nonisolated static func trim(url: URL, start: TimeInterval, end: TimeInterval) async throws -> TimeInterval {
        guard let fileType = writableFileType(for: url) else {
            throw TrimError.unsupportedFormat
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            throw TrimError.unreadable
        }

        let clampedStart = max(0, start)
        let clampedEnd = min(end, duration.seconds)
        guard clampedEnd - clampedStart >= 0.05 else {
            throw TrimError.invalidRange
        }

        let composition = AVMutableComposition()
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
              let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else {
            throw TrimError.unreadable
        }

        let timeRange = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: 600),
            end: CMTime(seconds: clampedEnd, preferredTimescale: 600)
        )
        do {
            try compositionTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
        } catch {
            throw TrimError.unreadable
        }

        let ext = fileType.rawValue.split(separator: ".").last.map(String.init) ?? url.pathExtension
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "flicksy-audio-trim-\(UUID().uuidString).\(url.pathExtension.isEmpty ? ext : url.pathExtension)")

        _ = try await composition.load(.duration)

        do {
            if fileType == .m4a {
                try await exportM4A(composition, to: temporary)
            } else {
                try await writePCM(composition, to: temporary, fileType: fileType)
            }
            try replaceItem(at: url, with: temporary)
        } catch let error as TrimError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw TrimError.exportFailed
        }

        return clampedEnd - clampedStart
    }

    // MARK: - Format

    nonisolated static func writableFileType(for url: URL) -> AVFileType? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "m4a", "aac":
            return .m4a
        case "wav":
            return .wav
        case "aif", "aiff":
            return .aiff
        case "caf":
            return .caf
        default:
            break
        }

        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .mpeg4Audio) { return .m4a }
        if type.conforms(to: .wav) { return .wav }
        if type.conforms(to: .aiff) { return .aiff }
        return nil
    }

    // MARK: - Export

    nonisolated private static func exportM4A(_ asset: AVAsset, to url: URL) async throws {
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let candidates = [
            AVAssetExportPresetPassthrough,
            AVAssetExportPresetAppleM4A,
        ].filter { presets.contains($0) }

        for preset in candidates {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset),
                  session.supportedFileTypes.contains(.m4a)
            else { continue }
            try await export(session, to: url, fileType: .m4a)
            return
        }

        throw TrimError.exportFailed
    }

    nonisolated private static func export(
        _ session: AVAssetExportSession,
        to url: URL,
        fileType: AVFileType
    ) async throws {
        session.outputURL = url
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        await session.export()
        guard session.status == .completed else {
            throw TrimError.exportFailed
        }
    }

    /// Decode the composition to 16-bit PCM and write it with Audio File Services.
    /// A synchronous reader loop avoids AVAssetWriter callbacks, which deadlock
    /// under the app's default MainActor isolation.
    nonisolated private static func writePCM(_ asset: AVAsset, to url: URL, fileType: AVFileType) async throws {
        let pcm = try await readLinearPCM(from: asset, bigEndian: fileType == .aiff)
        try writePCMFile(pcm, to: url, fileType: fileType)
    }

    nonisolated private static func readLinearPCM(from asset: AVAsset, bigEndian: Bool) async throws -> LinearPCM {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TrimError.unreadable
        }

        let descriptions = try await track.load(.formatDescriptions)
        let asbd = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = asbd?.mSampleRate ?? 44_100
        let channels = max(1, Int(asbd?.mChannelsPerFrame ?? 2))

        return try await Task.detached {
            let reader = try AVAssetReader(asset: asset)
            let readerSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: bigEndian,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else { throw TrimError.exportFailed }
            reader.add(output)
            guard reader.startReading() else { throw TrimError.exportFailed }

            var data = Data()
            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var length = 0
                var bytes: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &bytes
                )
                guard status == kCMBlockBufferNoErr, let bytes, length > 0 else { continue }
                data.append(UnsafeBufferPointer(start: bytes, count: length))
            }

            guard reader.status == .completed, !data.isEmpty else {
                throw TrimError.exportFailed
            }

            return LinearPCM(data: data, sampleRate: sampleRate, channels: channels, bigEndian: bigEndian)
        }.value
    }

    nonisolated private static func writePCMFile(_ pcm: LinearPCM, to url: URL, fileType: AVFileType) throws {
        try? FileManager.default.removeItem(at: url)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: pcm.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: pcm.bigEndian
                ? kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian
                : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * pcm.channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * pcm.channels),
            mChannelsPerFrame: UInt32(pcm.channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )

        let audioFileType: AudioFileTypeID
        switch fileType {
        case .aiff: audioFileType = kAudioFileAIFFType
        case .caf: audioFileType = kAudioFileCAFType
        default: audioFileType = kAudioFileWAVEType
        }

        var audioFile: AudioFileID?
        var status = AudioFileCreateWithURL(
            url as CFURL,
            audioFileType,
            &asbd,
            [.eraseFile],
            &audioFile
        )
        guard status == noErr, let audioFile else { throw TrimError.exportFailed }
        defer { AudioFileClose(audioFile) }

        var byteCount = UInt32(pcm.data.count)
        status = pcm.data.withUnsafeBytes { buffer in
            AudioFileWriteBytes(audioFile, false, 0, &byteCount, buffer.baseAddress!)
        }
        guard status == noErr, byteCount == pcm.data.count else {
            throw TrimError.exportFailed
        }
    }

    nonisolated private static func replaceItem(at url: URL, with temporary: URL) throws {
        do {
            let result = try FileManager.default.replaceItemAt(
                url,
                withItemAt: temporary,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
            if let result, result != url {
                try FileManager.default.moveItem(at: result, to: url)
            }
        } catch {
            throw TrimError.replaceFailed
        }
    }
}

private struct LinearPCM: Sendable {
    let data: Data
    let sampleRate: Double
    let channels: Int
    let bigEndian: Bool
}

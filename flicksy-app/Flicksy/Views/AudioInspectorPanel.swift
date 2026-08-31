//
//  AudioInspectorPanel.swift
//  Flicksy
//

import SwiftUI

/// Bottom inspector for the selected audio clip: waveform, in/out range,
/// loop, and trim-to-selection.
struct AudioInspectorPanel: View {
    let item: MediaItem

    @Environment(BrowserModel.self) private var model

    @State private var peaks: [Float] = []
    @State private var isLoadingWaveform = true
    @State private var waveformFailed = false
    @State private var metadata: MediaMetadataService.Metadata?
    @State private var playback: AudioPlayback?
    @State private var selection: ClosedRange<Double> = 0...1

    private static let waveformHeight: CGFloat = 88
    private static let fullRangeEpsilon = 0.008

    private var isActive: Bool { model.playingAudioID == item.id }
    private var isPlaying: Bool { playback?.isPlaying ?? false }
    private var duration: TimeInterval? { metadata?.duration ?? playback?.duration ?? item.duration }

    private var selectionTimes: ClosedRange<TimeInterval>? {
        guard let duration, duration > 0 else { return nil }
        return (selection.lowerBound * duration)...(selection.upperBound * duration)
    }

    private var isPartialSelection: Bool {
        selection.lowerBound > Self.fullRangeEpsilon || selection.upperBound < 1 - Self.fullRangeEpsilon
    }

    private var canTrim: Bool {
        isPartialSelection
            && !model.isApplyingAudioTrim
            && AudioTrimmer.canTrim(url: item.url)
    }

    private var minimumSelectionSpan: Double {
        guard let duration, duration > 0 else { return 0.005 }
        return max(0.005, 0.05 / duration)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                transport
                waveform
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
        .task(id: item.contentVersion) {
            peaks = []
            waveformFailed = false
            isLoadingWaveform = true
            await loadWaveform()
            await loadMetadata()
        }
        .onChange(of: item.id) { _, _ in
            resetSelection()
            if model.playingAudioID != item.id {
                model.playingAudioID = nil
            }
            replacePlaybackIfActive()
        }
        .onChange(of: item.contentVersion) { _, _ in
            resetSelection()
            replacePlaybackIfActive()
        }
        .onChange(of: isActive) { _, nowActive in
            if nowActive {
                startPlayback()
            } else {
                stopPlayback()
            }
        }
        .onChange(of: model.isAudioPlaying) { _, shouldPlay in
            guard isActive, let playback else { return }
            if shouldPlay {
                if !playback.isPlaying { playback.play() }
            } else if playback.isPlaying {
                playback.pause()
            }
        }
        .onChange(of: selection) { _, _ in
            applyRangeToPlayback()
        }
        .onChange(of: model.isAudioLooping) { _, looping in
            playback?.isLooping = looping
        }
        .onChange(of: playback?.isPlaying) { _, playing in
            if isActive {
                model.isAudioPlaying = playing ?? false
            }
        }
        .onChange(of: model.audioSeekRequestID) { _, _ in
            applyTransportSeek()
        }
        .onAppear {
            if isActive {
                startPlayback()
            }
        }
        .onDisappear {
            stopPlayback()
            if isActive {
                model.playingAudioID = nil
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            transportButton("backward.end.fill", help: "Jump to Start (⌘←)") {
                model.requestAudioSeek(.start)
            }
            transportButton("gobackward.5", help: "Rewind 5 Seconds (←)") {
                model.requestAudioSeek(.rewind)
            }
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Pause (Space)" : "Play (Space)")
            transportButton("goforward.5", help: "Forward 5 Seconds (→)") {
                model.requestAudioSeek(.forward)
            }
            transportButton("forward.end.fill", help: "Jump to End (⌘→)") {
                model.requestAudioSeek(.end)
            }

            Button {
                model.isAudioLooping.toggle()
            } label: {
                Image(systemName: model.isAudioLooping ? "repeat.1" : "repeat")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.isAudioLooping ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(model.isAudioLooping ? "Turn Loop Off" : "Loop Selection")

            Text(item.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(timeLabel)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if model.isApplyingAudioTrim {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Trim to Selection") {
                trimSelection()
            }
            .disabled(!canTrim)
            .help(trimHelp)
        }
    }

    @ViewBuilder
    private var waveform: some View {
        Group {
            if waveformFailed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Waveform unavailable")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: Self.waveformHeight, alignment: .leading)
            } else if isLoadingWaveform {
                WaveformLoadingView()
                    .frame(height: Self.waveformHeight)
                    .transition(.opacity)
            } else {
                WaveformView(
                    peaks: peaks,
                    progress: playback?.progress ?? 0,
                    selection: selection,
                    minimumSelectionSpan: minimumSelectionSpan,
                    onSeek: seek(toFraction:),
                    onSelectionChange: { selection = $0 }
                )
                .frame(height: Self.waveformHeight)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.32), value: isLoadingWaveform)
        .animation(.easeInOut(duration: 0.32), value: waveformFailed)
    }

    private var timeLabel: String {
        let current = MediaFormatting.clock(playback?.currentTime) ?? "0:00"
        let total = MediaFormatting.clock(duration) ?? "--:--"
        if isPartialSelection, let times = selectionTimes {
            let selected = MediaFormatting.clock(times.upperBound - times.lowerBound) ?? "--:--"
            return "\(current) / \(total)  ·  \(selected) selected"
        }
        return "\(current) / \(total)"
    }

    private var trimHelp: String {
        if !AudioTrimmer.canTrim(url: item.url) {
            return "This audio format cannot be trimmed in place."
        }
        if !isPartialSelection {
            return "Drag the handles to choose a range to keep."
        }
        return "Overwrite the file with the selected range"
    }

    // MARK: - Loading

    private func loadWaveform() async {
        waveformFailed = false
        let result = await WaveformService.shared.waveform(for: item.url)
        guard !Task.isCancelled else { return }
        if let result {
            peaks = result
        } else {
            waveformFailed = true
        }
        isLoadingWaveform = false
    }

    private func loadMetadata() async {
        let result = await MediaMetadataService.shared.metadata(for: item.url)
        guard !Task.isCancelled else { return }
        metadata = result
        applyRangeToPlayback()
    }

    // MARK: - Transport

    private func togglePlayback() {
        if isActive {
            model.isAudioPlaying.toggle()
        } else {
            model.playingAudioID = item.id
        }
    }

    private func transportButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func applyTransportSeek() {
        let controller = ensurePlayback()
        applyRangeToPlayback()
        switch model.audioSeekKind {
        case .start:
            controller.seek(toFraction: selection.lowerBound)
        case .end:
            controller.seek(toFraction: selection.upperBound)
        case .rewind:
            controller.skip(by: -AudioPlayback.skipInterval)
        case .forward:
            controller.skip(by: AudioPlayback.skipInterval)
        }
        if isActive, model.isAudioPlaying {
            controller.play()
        }
    }

    private func seek(toFraction fraction: Double) {
        if !isActive {
            model.playingAudioID = item.id
        }
        let controller = ensurePlayback()
        controller.seek(toFraction: fraction)
        if model.isAudioPlaying || !isActive {
            model.isAudioPlaying = true
            controller.play()
        }
    }

    private func startPlayback() {
        let controller = ensurePlayback()
        applyRangeToPlayback()
        if model.isAudioPlaying {
            controller.play()
        }
    }

    private func stopPlayback() {
        playback?.tearDown()
        playback = nil
    }

    private func replacePlaybackIfActive() {
        stopPlayback()
        if isActive {
            startPlayback()
        }
    }

    @discardableResult
    private func ensurePlayback() -> AudioPlayback {
        if let playback { return playback }
        let controller = AudioPlayback(url: item.url, duration: duration)
        controller.isLooping = model.isAudioLooping
        playback = controller
        applyRangeToPlayback()
        return controller
    }

    private func applyRangeToPlayback() {
        playback?.playbackRange = isPartialSelection ? selectionTimes : nil
    }

    private func resetSelection() {
        selection = 0...1
    }

    private func trimSelection() {
        guard let times = selectionTimes, canTrim else { return }
        model.trimSelectedAudio(start: times.lowerBound, end: times.upperBound)
    }
}

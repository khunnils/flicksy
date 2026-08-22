//
//  AudioRow.swift
//  MediaBrowser
//

import SwiftUI

/// A full-width audio row: name, running time, and an interactive waveform
/// (spec sections 8, 14 and 15).
///
/// No player exists until the user presses play or clicks the waveform. The row
/// then claims `BrowserModel.playingAudioID`; because that is a single value,
/// claiming it implicitly releases whichever row held it before, so at most one
/// audio player is ever alive.
struct AudioRow: View {
    let item: MediaItem

    @Environment(BrowserModel.self) private var model

    @State private var peaks: [Float] = []
    @State private var waveformFailed = false
    @State private var metadata: MediaMetadataService.Metadata?
    @State private var playback: AudioPlayback?

    /// A waveform position clicked while the row was idle, applied once the
    /// player exists.
    @State private var pendingSeekFraction: Double?

    private var isActive: Bool { model.playingAudioID == item.id }
    private var isSelected: Bool { model.selectedItemIDs.contains(item.id) }

    var body: some View {
        HStack(spacing: 12) {
            playButton

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Text(timeLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                waveform
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AnyShapeStyle(.separator),
                              lineWidth: isSelected ? 1 : 0.5)
        )
        .selectableCell(item, model: model)
        .mediaItemInteractions(item, model: model)
        .task(id: item.url.path) {
            await loadWaveform()
        }
        .task(id: item.url.path) {
            await loadMetadata()
        }
        .onChange(of: isActive) { _, nowActive in
            if nowActive {
                startPlayback()
            } else {
                stopPlayback()
            }
        }
        .onDisappear {
            stopPlayback()
            if isActive {
                model.playingAudioID = nil
            }
        }
    }

    private var playButton: some View {
        Button {
            toggle()
        } label: {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Pause" : "Play")
    }

    @ViewBuilder
    private var waveform: some View {
        if waveformFailed {
            // A file whose samples cannot be read is still worth listing and
            // still worth trying to play (spec section 24).
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text("Waveform unavailable")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: Self.waveformHeight, alignment: .leading)
        } else {
            WaveformView(
                peaks: peaks,
                progress: playback?.progress ?? 0,
                onSeek: seek(toFraction:)
            )
            .frame(height: Self.waveformHeight)
        }
    }

    private static let waveformHeight: CGFloat = 40

    private var isPlaying: Bool { playback?.isPlaying ?? false }

    /// The duration alone until a player exists, then a running position.
    private var timeLabel: String {
        let total = MediaFormatting.clock(metadata?.duration ?? playback?.duration) ?? "--:--"
        guard let playback else { return total }
        return "\(MediaFormatting.clock(playback.currentTime) ?? "0:00") / \(total)"
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
    }

    private func loadMetadata() async {
        let result = await MediaMetadataService.shared.metadata(for: item.url)
        guard !Task.isCancelled else { return }
        metadata = result
    }

    // MARK: - Playback

    private func toggle() {
        model.selectItem(item)
        guard let playback, isActive else {
            activate()
            return
        }
        playback.togglePlayPause()
    }

    /// Clicking anywhere on the waveform plays from that position, whether or not
    /// the row is already the active one.
    private func seek(toFraction fraction: Double) {
        model.selectItem(item)
        guard let playback else {
            pendingSeekFraction = fraction
            activate()
            return
        }
        playback.seek(toFraction: fraction)
        playback.play()
    }

    /// Claim the audio slot, which starts playback through `onChange(of: isActive)`.
    /// When this row already holds the slot but has no player — after being
    /// scrolled out and back — start directly, since the state would not change.
    private func activate() {
        if isActive {
            startPlayback()
        } else {
            model.playingAudioID = item.id
        }
    }

    private func startPlayback() {
        let controller = playback ?? AudioPlayback(url: item.url, duration: metadata?.duration)
        playback = controller

        if let fraction = pendingSeekFraction {
            pendingSeekFraction = nil
            controller.seek(toFraction: fraction)
        }
        controller.play()
    }

    private func stopPlayback() {
        playback?.tearDown()
        playback = nil
        pendingSeekFraction = nil
    }
}

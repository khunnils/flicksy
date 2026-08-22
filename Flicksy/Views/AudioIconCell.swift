//
//  AudioIconCell.swift
//  MediaBrowser
//

import SwiftUI

/// Compact Finder-style audio tile. Playback resources are created only after
/// the user presses the hover control, matching the lazy waveform rows.
struct AudioIconCell: View {
    let item: MediaItem

    @Environment(BrowserModel.self) private var model

    @State private var isHovering = false
    @State private var metadata: MediaMetadataService.Metadata?
    @State private var playback: AudioPlayback?

    private var isActive: Bool { model.playingAudioID == item.id }
    private var isSelected: Bool { model.selectedItemIDs.contains(item.id) }
    private var isPlaying: Bool { playback?.isPlaying ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.secondary.opacity(0.12) : Color(nsColor: .controlBackgroundColor))

                Image(systemName: "music.note")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .opacity(showsPlaybackControl ? 0 : 1)

                playButton
                    .opacity(showsPlaybackControl ? 1 : 0)
                    .scaleEffect(showsPlaybackControl ? 1 : 0.92)
                    .allowsHitTesting(showsPlaybackControl)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: isSelected ? 1.5 : 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .selectableCell(item, model: model)
            .onHover { isHovering = $0 }

            MediaCaption(title: item.name, subtitle: subtitle)
        }
        .mediaItemInteractions(item, model: model)
        .animation(.easeOut(duration: 0.12), value: showsPlaybackControl)
        .task(id: item.url.path) {
            metadata = await MediaMetadataService.shared.metadata(for: item.url)
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
            togglePlayback()
        } label: {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.primary.opacity(0.72))
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Pause" : "Play")
    }

    private var showsPlaybackControl: Bool { isHovering || isActive }

    private var subtitle: String? {
        MediaFormatting.duration(metadata?.duration) ?? MediaFormatting.fileSize(item.fileSize)
    }

    private func togglePlayback() {
        model.selectItem(item)
        guard let playback, isActive else {
            if isActive {
                startPlayback()
            } else {
                model.playingAudioID = item.id
            }
            return
        }
        playback.togglePlayPause()
    }

    private func startPlayback() {
        let controller = playback ?? AudioPlayback(url: item.url, duration: metadata?.duration)
        playback = controller
        controller.play()
    }

    private func stopPlayback() {
        playback?.tearDown()
        playback = nil
    }
}

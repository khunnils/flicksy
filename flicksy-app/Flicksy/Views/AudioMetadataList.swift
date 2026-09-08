import SwiftUI

/// The waveform is the browsing surface; metadata remains secondary.
struct AudioMetadataList: View {
    let items: [MediaItem]
    let selectionCoordinateSpace: String
    let onSelectionFrameChange: (MediaItem.ID, UUID, CGRect?) -> Void
    @Environment(BrowserModel.self) private var model
    @State private var width: CGFloat = 800

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                AudioWaveformRow(item: item, compact: width < 640,
                    selectionState: model.selectionState(for: item.id))
                    .id(item.id)
                    .reportSelectionFrame(for: item, coordinateSpace: selectionCoordinateSpace,
                                          onChange: onSelectionFrameChange)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct AudioWaveformRow: View {
    let item: MediaItem
    let compact: Bool
    let selectionState: MediaItemSelectionState
    @Environment(BrowserModel.self) private var model
    @State private var metadata: MediaMetadataService.Metadata?
    @State private var peaks: [Float] = []
    @State private var loading = true
    @State private var failed = false
    private var session: AudioAuditionController { model.audioAudition }
    private var active: Bool { session.item?.id == item.id }
    private var playing: Bool { active && session.playback?.isPlaying == true }
    private var duration: Double? { metadata?.duration ?? item.duration }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { session.toggle(item) } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle")
                        .font(.system(size: 23))
                        .foregroundStyle(playing ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(playing ? "Pause" : "Play")
                .accessibilityLabel("\(playing ? "Pause" : "Play") \(item.name)")

                identity
                    .frame(width: compact ? nil : 240, alignment: .leading)
                    .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
                    .mediaItemInteractions(item, model: model)
                if !compact { waveform }
                Text(MediaFormatting.clock(duration) ?? "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
            }
            if compact { waveform.padding(.leading, 35) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 12 : 14)
        .frame(minHeight: 68)
        .background(selectionState.isSelected ? Color.accentColor.opacity(0.09) : Color.clear)
        .selectableCell(item, model: model)
        .keyboardFocusOutline(isFocused: selectionState.isFocused, cornerRadius: 5, inset: 1)
        .overlay(alignment: .bottom) { Divider() }
        .mediaItemInteractions(item, model: model, draggable: false)
        .dropDestination(for: URL.self) { urls, _ in
            guard model.isCollectionSelected, model.sortKey == .manual else { return false }
            model.reorderCollectionURLs(urls, before: item)
            return urls.count == 1
        }
        .task(id: item.contentVersion) {
            metadata = nil
            let loaded = await MediaMetadataService.shared.metadata(for: item.url)
            guard !Task.isCancelled else { return }
            metadata = loaded
            model.noteListMetadata(for: item.id, loaded)
        }
        .task(id: item.contentVersion) {
            loading = true; failed = false; peaks = []
            let loaded = await WaveformService.shared.waveform(for: item.url)
            guard !Task.isCancelled else { return }
            peaks = loaded ?? []; failed = loaded == nil; loading = false
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                MediaOrganizationBadges(isFavorite: item.isFavorite, tags: item.tags)
            }
            Text([item.url.pathExtension.uppercased(), MediaFormatting.sampleRate(metadata?.sampleRate),
                  MediaFormatting.channels(metadata?.channelCount)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var waveform: some View {
        WaveformView(peaks: peaks, progress: active ? session.playback?.progress ?? 0 : 0,
            selection: active && session.rangeEnabled ? session.selection : 0...1,
            onSeek: { session.seek($0, in: item, audition: true) },
            duration: duration, showsTimeLabels: true,
            onScrub: { fraction, _ in session.seek(fraction, in: item, audition: false) })
            .frame(maxWidth: .infinity).frame(height: 38)
            .overlay {
                if loading || failed {
                    Text(loading ? "Loading waveform…" : "Waveform unavailable")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).background(.background)
                        .allowsHitTesting(false)
                }
            }
    }
}

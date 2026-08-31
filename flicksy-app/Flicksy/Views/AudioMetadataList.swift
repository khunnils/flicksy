//
//  AudioMetadataList.swift
//  MediaBrowser
//

import SwiftUI
import UniformTypeIdentifiers

/// Finder-style audio list with stable, scannable metadata columns. A horizontal
/// scroll view preserves the columns when the detail pane is narrow.
struct AudioMetadataList: View {
    let items: [MediaItem]
    let selectionCoordinateSpace: String
    let onSelectionFrameChange: (MediaItem.ID, UUID, CGRect?) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyVStack(spacing: 0) {
                header

                Divider()

                ForEach(items) { item in
                    AudioMetadataRow(item: item)
                        .id(item.id)
                        .reportSelectionFrame(
                            for: item,
                            coordinateSpace: selectionCoordinateSpace,
                            onChange: onSelectionFrameChange
                        )
                }
            }
            .frame(minWidth: AudioListColumns.totalWidth, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: AudioListColumns.spacing) {
            Color.clear.frame(width: AudioListColumns.play)
            columnHeader("Name", width: AudioListColumns.name, alignment: .leading)
            columnHeader("Kind", width: AudioListColumns.kind, alignment: .leading)
            columnHeader("Date Added", width: AudioListColumns.dateAdded)
            columnHeader("Duration", width: AudioListColumns.duration)
            columnHeader("Bit Rate", width: AudioListColumns.bitRate)
            columnHeader("Sample Rate", width: AudioListColumns.sampleRate)
            columnHeader("Channels", width: AudioListColumns.channels)
            columnHeader("Size", width: AudioListColumns.size)
        }
        .padding(.horizontal, AudioListColumns.horizontalPadding)
        .padding(.vertical, 7)
    }

    private func columnHeader(
        _ title: String,
        width: CGFloat,
        alignment: Alignment = .trailing
    ) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }
}

private enum AudioListColumns {
    static let play: CGFloat = 28
    static let name: CGFloat = 280
    static let kind: CGFloat = 140
    static let dateAdded: CGFloat = 110
    static let duration: CGFloat = 80
    static let bitRate: CGFloat = 90
    static let sampleRate: CGFloat = 100
    static let channels: CGFloat = 80
    static let size: CGFloat = 90
    static let spacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 8

    static let totalWidth = play + name + kind + dateAdded + duration + bitRate
        + sampleRate + channels + size + spacing * 8 + horizontalPadding * 2
}

private struct AudioMetadataRow: View {
    let item: MediaItem

    @Environment(BrowserModel.self) private var model

    @State private var metadata: MediaMetadataService.Metadata?

    private var isActive: Bool { model.playingAudioID == item.id }
    private var isSelected: Bool { model.selectedItemIDs.contains(item.id) }
    private var isPlaying: Bool { isActive && model.isAudioPlaying }

    var body: some View {
        HStack(spacing: AudioListColumns.spacing) {
            playButton
                .frame(width: AudioListColumns.play)

            HStack(spacing: 6) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                MediaOrganizationBadges(isFavorite: item.isFavorite, tags: item.tags)
            }
            .frame(width: AudioListColumns.name, alignment: .leading)

            value(kindDescription, width: AudioListColumns.kind, alignment: .leading)
            value(dateAddedDescription, width: AudioListColumns.dateAdded)
            value(MediaFormatting.clock(metadata?.duration), width: AudioListColumns.duration)
            value(MediaFormatting.bitRate(metadata?.bitRate), width: AudioListColumns.bitRate)
            value(MediaFormatting.sampleRate(metadata?.sampleRate), width: AudioListColumns.sampleRate)
            value(MediaFormatting.channels(metadata?.channelCount), width: AudioListColumns.channels)
            value(MediaFormatting.fileSize(item.fileSize), width: AudioListColumns.size)
        }
        .font(.callout)
        .padding(.horizontal, AudioListColumns.horizontalPadding)
        .padding(.vertical, 6)
        .background(isSelected ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .contentShape(Rectangle())
        .selectableCell(item, model: model)
        .mediaItemInteractions(item, model: model)
        .dropDestination(for: URL.self) { urls, _ in
            guard model.isCollectionSelected, model.sortKey == .manual else { return false }
            model.reorderCollectionURLs(urls, before: item)
            return urls.count == 1
        }
        .task(id: item.contentVersion) {
            metadata = await MediaMetadataService.shared.metadata(for: item.url)
        }
    }

    private var playButton: some View {
        Button {
            togglePlayback()
        } label: {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Pause" : "Play")
    }

    private var kindDescription: String? {
        let fileExtension = item.url.pathExtension
        guard !fileExtension.isEmpty else { return nil }
        return UTType(filenameExtension: fileExtension)?.localizedDescription
            ?? fileExtension.uppercased()
    }

    private var dateAddedDescription: String? {
        item.addedAt?.formatted(date: .abbreviated, time: .omitted)
    }

    private func value(
        _ text: String?,
        width: CGFloat,
        alignment: Alignment = .trailing
    ) -> some View {
        Text(text ?? "—")
            .foregroundStyle(text == nil ? .tertiary : .secondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private func togglePlayback() {
        model.selectItem(item)
        if isActive {
            model.isAudioPlaying.toggle()
        } else {
            model.playingAudioID = item.id
        }
    }
}

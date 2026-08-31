//
//  AllMetadataList.swift
//  Flicksy
//

import SwiftUI
import UniformTypeIdentifiers

/// Finder-style list for scanning every supported media type together. Columns
/// are intentionally limited to metadata that is meaningful across media types.
struct AllMetadataList: View {
    let items: [MediaItem]
    let selectionCoordinateSpace: String
    let onSelectionFrameChange: (MediaItem.ID, UUID, CGRect?) -> Void

    @Environment(BrowserModel.self) private var model

    var body: some View {
        // Read selection in the parent so LazyVStack rows receive an explicit
        // `isSelected` input. Rows that only observe the model via Environment
        // can miss invalidation and keep a stale highlight.
        let selectedIDs = model.selectedItemIDs

        ScrollView(.horizontal) {
            LazyVStack(spacing: 0) {
                header
                Divider()

                ForEach(items) { item in
                    AllMetadataRow(
                        item: item,
                        isSelected: selectedIDs.contains(item.id)
                    )
                        .id(item.id)
                        .reportSelectionFrame(
                            for: item,
                            coordinateSpace: selectionCoordinateSpace,
                            onChange: onSelectionFrameChange
                        )
                }
            }
            .frame(minWidth: AllListColumns.totalWidth, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: AllListColumns.spacing) {
            Color.clear.frame(width: AllListColumns.action)
            columnHeader("Name", width: AllListColumns.name, alignment: .leading)
            columnHeader("Kind", width: AllListColumns.kind, alignment: .leading)
            columnHeader("Date Added", width: AllListColumns.dateAdded)
            columnHeader("Date Modified", width: AllListColumns.dateModified)
            columnHeader("Duration", width: AllListColumns.duration)
            columnHeader("Dimensions", width: AllListColumns.dimensions)
            columnHeader("Size", width: AllListColumns.size)
        }
        .padding(.horizontal, AllListColumns.horizontalPadding)
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

private enum AllListColumns {
    static let action: CGFloat = 28
    static let name: CGFloat = 280
    static let kind: CGFloat = 140
    static let dateAdded: CGFloat = 110
    static let dateModified: CGFloat = 110
    static let duration: CGFloat = 80
    static let dimensions: CGFloat = 100
    static let size: CGFloat = 90
    static let spacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 8

    static let totalWidth = action + name + kind + dateAdded + dateModified
        + duration + dimensions + size + spacing * 7 + horizontalPadding * 2
}

private struct AllMetadataRow: View {
    let item: MediaItem
    let isSelected: Bool

    @Environment(BrowserModel.self) private var model

    @State private var metadata: MediaMetadataService.Metadata?
    @State private var audioPlayback: AudioPlayback?

    private var isActiveAudio: Bool {
        item.type == .audio && model.playingAudioID == item.id
    }

    private var isPlayingAudio: Bool { audioPlayback?.isPlaying ?? false }

    var body: some View {
        HStack(spacing: AllListColumns.spacing) {
            actionButton
                .frame(width: AllListColumns.action)

            HStack(spacing: 6) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                MediaOrganizationBadges(isFavorite: item.isFavorite, tags: item.tags)
            }
            .frame(width: AllListColumns.name, alignment: .leading)

            value(kindDescription, width: AllListColumns.kind, alignment: .leading)
            value(dateAddedDescription, width: AllListColumns.dateAdded)
            value(dateModifiedDescription, width: AllListColumns.dateModified)
            value(durationDescription, width: AllListColumns.duration)
            value(dimensionsDescription, width: AllListColumns.dimensions)
            value(MediaFormatting.fileSize(item.fileSize), width: AllListColumns.size)
        }
        .font(.callout)
        .padding(.horizontal, AllListColumns.horizontalPadding)
        .padding(.vertical, 6)
        .background {
            Rectangle()
                .fill(.quaternary.opacity(isSelected ? 0.5 : 0))
        }
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
            guard item.type != .image else { return }
            metadata = await MediaMetadataService.shared.metadata(for: item.url)
        }
        .onChange(of: isActiveAudio) { _, nowActive in
            if nowActive {
                startAudioPlayback()
            } else {
                stopAudioPlayback()
            }
        }
        .onDisappear {
            stopAudioPlayback()
            if isActiveAudio {
                model.playingAudioID = nil
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch item.type {
        case .audio:
            Button {
                toggleAudioPlayback()
            } label: {
                Image(systemName: isPlayingAudio ? "pause.circle.fill" : "play.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isPlayingAudio ? "Pause" : "Play")
        case .video:
            Button {
                model.selectItem(item)
                model.openViewer(item)
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Play in Preview")
        case .image:
            Image(systemName: "photo")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
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

    private var dateModifiedDescription: String? {
        item.modifiedAt?.formatted(date: .abbreviated, time: .omitted)
    }

    private var durationDescription: String? {
        guard item.type != .image else { return nil }
        return MediaFormatting.clock(metadata?.duration ?? item.duration)
    }

    private var dimensionsDescription: String? {
        guard item.type != .audio else { return nil }
        let width = metadata?.width ?? item.width
        let height = metadata?.height ?? item.height
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
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

    private func toggleAudioPlayback() {
        model.selectItem(item)
        guard let audioPlayback, isActiveAudio else {
            if isActiveAudio {
                startAudioPlayback()
            } else {
                model.playingAudioID = item.id
            }
            return
        }
        audioPlayback.togglePlayPause()
    }

    private func startAudioPlayback() {
        let controller = audioPlayback
            ?? AudioPlayback(url: item.url, duration: metadata?.duration ?? item.duration)
        audioPlayback = controller
        controller.play()
    }

    private func stopAudioPlayback() {
        audioPlayback?.tearDown()
        audioPlayback = nil
    }
}

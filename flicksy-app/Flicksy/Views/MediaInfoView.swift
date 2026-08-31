//
//  MediaInfoView.swift
//  Flicksy
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder-inspired single-file inspector with catalog tag editing.
struct MediaInfoView: View {
    static let windowID = "media-info"

    let item: MediaItem

    @Environment(BrowserModel.self) private var model
    @State private var metadata: MediaMetadataService.Metadata?
    @State private var imageDimensions: CGSize?
    @State private var appliedTagIDs: Set<UUID> = []
    @State private var isCreatingTag = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                generalSection
                tagsSection
            }
            .padding(20)
        }
        .frame(width: 440, height: 560)
        .navigationTitle("\(item.name) Info")
        .task(id: item.contentVersion) {
            await loadMetadata()
            appliedTagIDs = await model.tagIDs(for: item)
        }
        .sheet(isPresented: $isCreatingTag) {
            TagEditor(title: "New Tag", initialName: "", initialColor: .gray) { name, color in
                model.createTag(name: name, color: color, applyingTo: item)
            }
        }
        .onChange(of: model.tags.map(\.id)) {
            Task { appliedTagIDs = await model.tagIDs(for: item) }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: fileIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(kindDescription)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var generalSection: some View {
        GroupBox("General") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                infoRow("Kind", kindDescription)
                infoRow("Size", sizeDescription)
                infoRow("Where", item.url.deletingLastPathComponent().path)
                infoRow("Date Added", dateDescription(item.addedAt))
                infoRow("Modified", dateDescription(item.modifiedAt))

                if item.type != .image {
                    infoRow("Duration", MediaFormatting.clock(metadata?.duration ?? item.duration) ?? "—")
                }
                if item.type != .audio {
                    infoRow("Dimensions", dimensionsDescription ?? "—")
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        GroupBox("Tags") {
            VStack(alignment: .leading, spacing: 9) {
                if item.libraryID == nil {
                    Text("Tags are available for files inside an added library folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if model.tags.isEmpty {
                        Text("No tags yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.tags) { tag in
                            Toggle(isOn: Binding(
                                get: { appliedTagIDs.contains(tag.id) },
                                set: { enabled in
                                    if enabled {
                                        appliedTagIDs.insert(tag.id)
                                    } else {
                                        appliedTagIDs.remove(tag.id)
                                    }
                                    model.setTag(tag, enabled: enabled, on: item)
                                }
                            )) {
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(tag.color.color)
                                        .frame(width: 9, height: 9)
                                    Text(tag.name)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }

                    Button("New Tag…") { isCreatingTag = true }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .lineLimit(label == "Where" ? 2 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }

    private var fileIcon: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }

    private var kindDescription: String {
        let fileExtension = item.url.pathExtension
        guard !fileExtension.isEmpty else { return item.type.title }
        return UTType(filenameExtension: fileExtension)?.localizedDescription
            ?? fileExtension.uppercased()
    }

    private var sizeDescription: String {
        guard let fileSize = item.fileSize else { return "—" }
        let formatted = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        return "\(formatted) (\(fileSize.formatted()) bytes)"
    }

    private var dimensionsDescription: String? {
        let width = metadata?.width ?? imageDimensions.map { Int($0.width) } ?? item.width
        let height = metadata?.height ?? imageDimensions.map { Int($0.height) } ?? item.height
        return MediaFormatting.dimensions(width: width, height: height)
    }

    private func dateDescription(_ date: Date?) -> String {
        date?.formatted(date: .long, time: .shortened) ?? "—"
    }

    private func loadMetadata() async {
        switch item.type {
        case .image:
            if let thumbnail = await ThumbnailService.shared.thumbnail(for: item.url, targetPixels: 256),
               let width = thumbnail.pixelWidth,
               let height = thumbnail.pixelHeight {
                imageDimensions = CGSize(width: width, height: height)
            }
        case .video, .audio:
            metadata = await MediaMetadataService.shared.metadata(for: item.url)
        }
    }
}

private extension MediaType {
    var title: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        }
    }
}

//
//  MediaCell.swift
//  MediaBrowser
//

import AppKit
import SwiftUI

/// Frames of the currently rendered media elements in the browser's selection
/// coordinate space. Lazy containers automatically remove off-screen entries,
/// so marquee hit testing never uses stale cell positions.
struct MediaSelectionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [MediaItem.ID: CGRect] = [:]

    static func reduce(
        value: inout [MediaItem.ID: CGRect],
        nextValue: () -> [MediaItem.ID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

/// Shared visual chrome for grid cells. Selection uses layered neutral edges so
/// it stays visible over light or dark media without competing with the image.
struct MediaCardBackground<Content: View>: View {
    var isSelected: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                isSelected
                    ? AnyShapeStyle(Color.primary.opacity(0.055))
                    : AnyShapeStyle(.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(Color.primary.opacity(0.52)) : AnyShapeStyle(.clear),
                        lineWidth: isSelected ? 1.5 : 0
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .inset(by: 2)
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.38) : .clear,
                        lineWidth: isSelected ? 0.75 : 0
                    )
            }
            .shadow(
                color: isSelected ? Color.black.opacity(0.2) : .clear,
                radius: isSelected ? 4 : 0,
                y: isSelected ? 1 : 0
            )
    }
}

/// Centers media on a subtle mat shared by every item in the grid. The mat
/// follows the folder's card ratio while the media keeps its own aspect ratio.
struct MediaThumbnailSurface<Content: View>: View {
    let aspectRatio: CGFloat
    var isSelected: Bool = false
    var inset: CGFloat = 7
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let contentSize = fittedContentSize(in: proxy.size)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(Color.primary.opacity(0.09))
                            : AnyShapeStyle(Color(white: 0.97))
                    )

                content
                    .frame(width: contentSize.width, height: contentSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? AnyShapeStyle(Color.primary.opacity(0.4)) : AnyShapeStyle(.clear),
                            lineWidth: isSelected ? 1.5 : 0
                        )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .inset(by: 2)
                        .strokeBorder(
                            isSelected ? Color.white.opacity(0.38) : .clear,
                            lineWidth: isSelected ? 0.75 : 0
                        )
                }
                .shadow(
                    color: isSelected ? Color.black.opacity(0.2) : .clear,
                    radius: isSelected ? 4 : 0,
                    y: isSelected ? 1 : 0
                )
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private func fittedContentSize(in container: CGSize) -> CGSize {
        MediaThumbnailLayout.fittedContentSize(
            aspectRatio: aspectRatio,
            inset: inset,
            container: container
        )
    }
}

enum MediaThumbnailLayout {
    static func fittedContentSize(
        aspectRatio: CGFloat,
        inset: CGFloat = 7,
        container: CGSize
    ) -> CGSize {
        let availableWidth = max(0, container.width - inset * 2)
        let availableHeight = max(0, container.height - inset * 2)
        guard availableWidth > 0, availableHeight > 0, aspectRatio > 0 else {
            return .zero
        }

        let width = min(availableWidth, availableHeight * aspectRatio)
        return CGSize(width: width, height: width / aspectRatio)
    }

    static func contentLeadingInset(aspectRatio: CGFloat, container: CGSize) -> CGFloat {
        let contentWidth = fittedContentSize(
            aspectRatio: aspectRatio,
            container: container
        ).width
        return max(0, (container.width - contentWidth) / 2)
    }
}

extension View {
    /// Reports this element's full hit area for empty-space drag selection.
    func reportSelectionFrame(
        for item: MediaItem,
        coordinateSpace: String
    ) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MediaSelectionFramePreferenceKey.self,
                    value: [item.id: proxy.frame(in: .named(coordinateSpace))]
                )
            }
        }
    }

    /// Finder-style click-to-select behaviour for a media element.
    ///
    /// Selection happens as soon as the pointer goes down, so it does not wait for
    /// the double-click recognizer to fail. A double click still opens the preview.
    func selectableCell(_ item: MediaItem, model: BrowserModel) -> some View {
        modifier(SelectableCellModifier(item: item, model: model))
    }
}

private struct SelectableCellModifier: ViewModifier {
    let item: MediaItem
    let model: BrowserModel

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0)
                    .onEnded { _ in select() }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded { model.previewItem(item) }
            )
    }

    private func select() {
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        model.selectItem(
            item,
            toggle: modifiers.contains(.command) || modifiers.contains(.control),
            extend: modifiers.contains(.shift)
        )
    }
}

/// Failure state shown when a file cannot be decoded (spec section 24). Browsing
/// of the surrounding media continues normally.
struct PreviewUnavailable: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Preview unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(8)
    }
}

/// One- or two-line caption used beneath grid cells, plus optional organization
/// chrome (favorite star and tag color dots). Color appears only on these dots
/// and never tints the media itself.
struct MediaCaption: View {
    let title: String
    let subtitle: String?
    var isFavorite: Bool = false
    var tags: [LibraryTag] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            MediaOrganizationBadges(isFavorite: isFavorite, tags: tags)
                .padding(.top, isFavorite || !tags.isEmpty ? 2 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small favorite star and up to a few tag color dots. Renders nothing when the
/// item is neither favorited nor tagged so unorganized cells stay clean.
struct MediaOrganizationBadges: View {
    let isFavorite: Bool
    let tags: [LibraryTag]
    var maxDots = 4

    var body: some View {
        if isFavorite || !tags.isEmpty {
            HStack(spacing: 4) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Favorite")
                }
                ForEach(tags.prefix(maxDots)) { tag in
                    Circle()
                        .fill(tag.color.color)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(tag.name)
                }
                if tags.count > maxDots {
                    Text("+\(tags.count - maxDots)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(tags.count - maxDots) more tags")
                }
            }
        }
    }
}

/// Formats values used in cell captions.
enum MediaFormatting {
    static func fileSize(_ bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Short clips read as `8.3s` because tenths matter when picking between
    /// near-identical takes; anything a minute or longer uses clock notation.
    static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }

        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }

        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// `m:ss` clock for the audio transport, where a steadily counting readout is
    /// easier to follow than the fractional-seconds form used on video cells.
    static func clock(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }

        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func dimensions(width: Int?, height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    static func bitRate(_ bitsPerSecond: Int?) -> String? {
        guard let bitsPerSecond, bitsPerSecond > 0 else { return nil }
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
        }
        return "\(Int((Double(bitsPerSecond) / 1_000).rounded())) kbps"
    }

    static func sampleRate(_ samplesPerSecond: Double?) -> String? {
        guard let samplesPerSecond, samplesPerSecond.isFinite, samplesPerSecond > 0 else { return nil }
        let kilohertz = samplesPerSecond / 1_000
        return kilohertz.rounded() == kilohertz
            ? String(format: "%.0f kHz", kilohertz)
            : String(format: "%.1f kHz", kilohertz)
    }

    static func channels(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(count) ch"
        }
    }

    /// Joins the caption details that are available, e.g. `8.3s · 1920×1080`.
    static func detailLine(_ parts: [String?]) -> String? {
        let available = parts.compactMap { $0 }
        return available.isEmpty ? nil : available.joined(separator: " · ")
    }
}

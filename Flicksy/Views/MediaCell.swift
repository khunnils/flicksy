//
//  MediaCell.swift
//  MediaBrowser
//

import SwiftUI

/// Shared visual chrome for grid cells: a rounded, subtly bordered card that
/// clips its content.
struct MediaCardBackground<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
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

/// One- or two-line caption used beneath grid cells.
struct MediaCaption: View {
    let title: String
    let subtitle: String?

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Joins the caption details that are available, e.g. `8.3s · 1920×1080`.
    static func detailLine(_ parts: [String?]) -> String? {
        let available = parts.compactMap { $0 }
        return available.isEmpty ? nil : available.joined(separator: " · ")
    }
}

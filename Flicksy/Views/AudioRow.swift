//
//  AudioRow.swift
//  MediaBrowser
//

import SwiftUI

/// Milestone 1 placeholder for an audio item.
///
/// Audio is rendered as a full-width row rather than a square card (spec section
/// 8). Real waveform rendering, click-to-seek and playback arrive in Milestone 3;
/// this row reserves the same full-width layout so the waveform can drop straight
/// into `waveformPlaceholder` later.
struct AudioRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                waveformPlaceholder

                if let size = MediaFormatting.fileSize(item.fileSize) {
                    Text(size)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Static stand-in for the waveform added in Milestone 3.
    private var waveformPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.quaternary)
            .frame(height: 28)
            .overlay(
                Image(systemName: "waveform")
                    .foregroundStyle(.tertiary)
            )
    }
}

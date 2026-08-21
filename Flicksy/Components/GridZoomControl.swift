//
//  GridZoomControl.swift
//  MediaBrowser
//

import SwiftUI

/// Toolbar control for thumbnail size: zoom out, a slider, and zoom in.
struct GridZoomControl: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 10) {
            zoomButton(
                "minus.magnifyingglass",
                label: "Zoom Out",
                disabled: model.thumbnailSize <= BrowserModel.minThumbnailSize,
                action: model.zoomOut
            )

            Slider(
                value: $model.thumbnailSize,
                in: BrowserModel.minThumbnailSize...BrowserModel.maxThumbnailSize
            )
            .frame(width: 108)
            .controlSize(.small)
            .help("Thumbnail size")
            .accessibilityLabel("Thumbnail size")

            zoomButton(
                "plus.magnifyingglass",
                label: "Zoom In",
                disabled: model.thumbnailSize >= BrowserModel.maxThumbnailSize,
                action: model.zoomIn
            )
        }
        .padding(.horizontal, 4)
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .fixedSize()
    }

    private func zoomButton(
        _ systemImage: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

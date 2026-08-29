//
//  ImageViewerChrome.swift
//  Flicksy
//

import AppKit
import SwiftUI

/// Window-toolbar controls shown while the focused media viewer is open.
struct ImageViewerToolbar: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if model.isViewingImage {
                if model.isCropping {
                    cropEditingControls
                } else {
                    toolbarIconButton("crop", label: "Crop", action: model.beginCrop)
                    ImageViewerZoomControl()
                }
            }

            toolbarIconButton(
                "arrow.up.left.and.arrow.down.right",
                label: "Full Screen",
                action: { NSApplication.shared.keyWindow?.toggleFullScreen(nil) }
            )
            .help("Toggle Full Screen (F)")

            closeButton
        }
    }

    private var cropEditingControls: some View {
        HStack(spacing: 8) {
            aspectMenu

            Button("Cancel") {
                model.cancelCrop()
            }
            .help("Cancel crop (Esc)")
            .keyboardShortcut(.cancelAction)
            .disabled(model.isApplyingCrop)

            Button("Apply") {
                model.applyCrop()
            }
            .buttonStyle(.borderedProminent)
            .help("Apply crop and overwrite the original image")
            .disabled(model.isApplyingCrop)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var aspectMenu: some View {
        Menu {
            ForEach(CropAspectRatio.allCases) { option in
                Button {
                    model.setCropAspect(option)
                } label: {
                    HStack {
                        Text(option.title)
                        if model.cropAspect == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label(model.cropAspect.title, systemImage: "aspectratio")
        }
        .help("Lock crop guide to an aspect ratio")
    }

    @ViewBuilder
    private var closeButton: some View {
        let button = toolbarIconButton("xmark", label: "Close", action: model.closeViewer)
            .help("Close viewer (Esc)")
            .disabled(model.isApplyingCrop)
        if model.isCropping {
            button
        } else {
            button.keyboardShortcut(.cancelAction)
        }
    }

    private func toolbarIconButton(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

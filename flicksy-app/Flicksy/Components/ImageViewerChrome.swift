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
            if model.isViewingImage && !model.isComparingImages {
                if model.isCropping {
                    cropEditingControls
                } else {
                    toolbarIconButton("aspectratio", label: "Resize Image…", action: model.presentImageResize)
                        .disabled(model.isApplyingCrop)
                    toolbarIconButton("crop", label: "Crop", action: model.beginCrop)
                        .disabled(model.isApplyingCrop)
                }
                rotateMenu
                flipMenu
                ImageViewerZoomControl()
            }

            if model.canCompareSelectedImages && !model.isCropping {
                compareButton
                if model.isComparingImages {
                    compareLayoutControls
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
        .padding(.horizontal, 8)
    }

    private var compareButton: some View {
        Button(action: model.toggleImageComparison) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(model.isComparingImages ? Color.accentColor : Color.primary)
                .frame(width: 28, height: 22)
                .background(
                    model.isComparingImages ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.isComparingImages ? "Return to single preview (⇧Space)" : "Compare selected images (⇧Space)")
        .accessibilityLabel(model.isComparingImages ? "Exit Compare" : "Compare Images")
    }

    private var compareLayoutControls: some View {
        HStack(spacing: 2) {
            ForEach(MediaCompareLayout.allCases) { layout in
                Button {
                    model.setImageComparisonLayout(layout)
                } label: {
                    CompareLayoutIcon(layout: layout)
                        .foregroundStyle(
                            model.compareLayout == layout ? Color.accentColor : Color.primary
                        )
                        .frame(width: 25, height: 22)
                        .background(
                            model.compareLayout == layout ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!layout.isAvailable(for: model.comparisonImages.count))
                .help("Compare \(layout.title)")
                .accessibilityLabel("Compare layout \(layout.title)")
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
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
            .buttonStyle(.plain)
            .fontWeight(.semibold)
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
            HStack(spacing: 5) {
                Image(systemName: "aspectratio")
                Text(model.cropAspect.title)
            }
            .foregroundStyle(.primary)
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .help("Lock crop guide to an aspect ratio")
    }

    private var rotateMenu: some View {
        Menu {
            Button("Rotate Left", systemImage: "rotate.left", action: model.rotateViewerImageLeft)
            Button("Rotate Right", systemImage: "rotate.right", action: model.rotateViewerImageRight)
        } label: {
            toolbarMenuIcon("rotate.right")
        }
        .menuStyle(.borderlessButton)
        .disabled(model.isCropping || model.isApplyingCrop)
        .help("Rotate image")
        .accessibilityLabel("Rotate image")
    }

    private var flipMenu: some View {
        Menu {
            Button("Flip Horizontally", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", action: model.flipViewerImageHorizontal)
            Button("Flip Vertically", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down", action: model.flipViewerImageVertical)
        } label: {
            toolbarMenuIcon("arrow.left.and.right.righttriangle.left.righttriangle.right")
        }
        .menuStyle(.borderlessButton)
        .disabled(model.isCropping || model.isApplyingCrop)
        .help("Flip image")
        .accessibilityLabel("Flip image")
    }

    private func toolbarMenuIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 28, height: 22)
            .contentShape(Rectangle())
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

/// Tiny layout glyph used because SF Symbols does not provide every 1x3/3x1
/// permutation. The geometry mirrors the columns x rows naming exactly.
private struct CompareLayoutIcon: View {
    let layout: MediaCompareLayout

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<layout.rows, id: \.self) { _ in
                HStack(spacing: 1.5) {
                    ForEach(0..<layout.columns, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 0.8)
                            .strokeBorder(lineWidth: 1.1)
                    }
                }
            }
        }
        .frame(width: 16, height: 14)
    }
}

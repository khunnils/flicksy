//
//  ImageResizeView.swift
//  Flicksy
//

import SwiftUI

/// Modal exact-pixel editor for a single still image. File I/O is deferred until
/// Apply so cancelling the sheet never mutates the original.
struct ImageResizeView: View {
    let item: MediaItem

    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ImageResizeDraft?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case width
        case height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Resize Image")
                    .font(.headline)
                Text(item.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading image dimensions…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else if let draft {
                dimensionEditor(draft)
            } else {
                ContentUnavailableView(
                    "Dimensions Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This image could not be opened for resizing.")
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            }

            if let message = validationMessage ?? saveError {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Applying this change replaces the original image.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isSaving)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding(20)
        .frame(width: 400)
        .task(id: item.contentVersion) { await loadDimensions() }
        .interactiveDismissDisabled(isSaving)
    }

    private func dimensionEditor(_ current: ImageResizeDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Original: \(current.sourceWidth) × \(current.sourceHeight) pixels")
                .font(.callout)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Width:")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    pixelField(text: widthBinding, field: .width)
                    Text("px").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Height:")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    pixelField(text: heightBinding, field: .height)
                    Text("px").foregroundStyle(.secondary)
                }
            }

            Toggle("Keep aspect ratio", isOn: aspectLockBinding)
                .toggleStyle(.checkbox)
                .disabled(isSaving)
        }
    }

    private func pixelField(text: Binding<String>, field: Field) -> some View {
        TextField("Pixels", text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 130)
            .focused($focusedField, equals: field)
            .disabled(isSaving)
    }

    private var widthBinding: Binding<String> {
        Binding(
            get: { draft?.widthText ?? "" },
            set: { value in
                guard var next = draft else { return }
                next.setWidthText(value)
                draft = next
                saveError = nil
            }
        )
    }

    private var heightBinding: Binding<String> {
        Binding(
            get: { draft?.heightText ?? "" },
            set: { value in
                guard var next = draft else { return }
                next.setHeightText(value)
                draft = next
                saveError = nil
            }
        )
    }

    private var aspectLockBinding: Binding<Bool> {
        Binding(
            get: { draft?.isAspectRatioLocked ?? true },
            set: { locked in
                draft?.isAspectRatioLocked = locked
                saveError = nil
            }
        )
    }

    private var validationMessage: String? {
        guard !isLoading, let draft, draft.targetSize == nil else { return nil }
        return "Width and height must be positive whole numbers."
    }

    private var canApply: Bool {
        !isLoading && !isSaving && draft?.canApply == true
    }

    private func loadDimensions() async {
        isLoading = true
        saveError = nil
        let url = item.url
        let size = await Task.detached(priority: .userInitiated) {
            ThumbnailService.pixelSize(for: url)
        }.value
        guard !Task.isCancelled else { return }
        draft = size.flatMap(ImageResizeDraft.init(sourceSize:))
        isLoading = false
        focusedField = .width
    }

    private func apply() {
        guard !isSaving, let targetSize = draft?.targetSize, draft?.isChanged == true else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await model.resizeImage(item, to: targetSize)
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

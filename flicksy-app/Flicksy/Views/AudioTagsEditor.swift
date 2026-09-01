//
//  AudioTagsEditor.swift
//  Flicksy
//

import SwiftUI

/// Modal editor for MP3 ID3 tags. Nothing is written until OK.
struct AudioTagsEditor: View {
    let item: MediaItem

    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AudioTags.empty
    @State private var original = AudioTags.empty
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var saveError: String?

    private var fieldsDisabled: Bool { isSaving || isLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Meta Tags")
                    .font(.headline)
                Text(item.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        field("Name", $draft.title)
                        field("Artist", $draft.artist)
                        field("Album Artist", $draft.albumArtist)
                        field("Album", $draft.album)
                        field("Grouping", $draft.grouping)
                        field("Composer", $draft.composer)
                        field("Comments", $draft.comments)
                        field("Genre", $draft.genre)
                        field("Year", $draft.year)
                        indexRow("Track", number: $draft.trackNumber, count: $draft.trackCount)
                        indexRow("Disc Number", number: $draft.discNumber, count: $draft.discCount)
                        field("BPM", $draft.bpm)
                    }

                    Toggle(isOn: $draft.isCompilation) {
                        Text("Album is a compilation of songs by various artists")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(fieldsDisabled)

                    if let saveError {
                        Text(saveError)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .disabled(isSaving)
                Button("OK") {
                    apply()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fieldsDisabled)
            }
        }
        .padding(20)
        .frame(width: 440, height: 560)
        .task(id: item.id) {
            await reload()
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        GridRow {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(fieldsDisabled)
                .gridColumnAlignment(.leading)
        }
    }

    private func indexRow(
        _ label: String,
        number: Binding<String>,
        count: Binding<String>
    ) -> some View {
        GridRow {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            HStack(spacing: 8) {
                TextField("", text: number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .disabled(fieldsDisabled)
                Text("of")
                    .foregroundStyle(.secondary)
                TextField("", text: count)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .disabled(fieldsDisabled)
                Spacer(minLength: 0)
            }
            .gridColumnAlignment(.leading)
        }
    }

    private func reload() async {
        isLoading = true
        saveError = nil
        let loaded = await AudioTagService.load(from: item.url)
        guard !Task.isCancelled else { return }
        draft = loaded
        original = loaded
        isLoading = false
    }

    private func apply() {
        let next = draft.normalized
        guard !isSaving, !isLoading else { return }
        if next == original.normalized {
            dismiss()
            return
        }

        isSaving = true
        saveError = nil
        Task {
            do {
                try await model.saveAudioTags(next, for: item)
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

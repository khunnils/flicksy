//
//  AudioTagsEditor.swift
//  Flicksy
//

import SwiftUI

/// Modal editor for MP3 ID3 tags. Nothing is written until OK. When several
/// files are open, Name is locked and only fields the user edits are written,
/// so mixed values such as track numbers stay per-file.
struct AudioTagsEditor: View {
    let items: [MediaItem]

    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AudioTags.empty
    @State private var original = AudioTags.empty
    @State private var mixed: Set<AudioTagField> = []
    @State private var originalMixed: Set<AudioTagField> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var saveError: String?

    private var isMultiple: Bool { items.count > 1 }
    private var fieldsDisabled: Bool { isSaving || isLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Meta Tags")
                    .font(.headline)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        field("Name", .title, \.title, disabled: isMultiple)
                        field("Artist", .artist, \.artist)
                        field("Album Artist", .albumArtist, \.albumArtist)
                        field("Album", .album, \.album)
                        field("Grouping", .grouping, \.grouping)
                        field("Composer", .composer, \.composer)
                        field("Comments", .comments, \.comments)
                        field("Genre", .genre, \.genre)
                        field("Year", .year, \.year)
                        indexRow("Track", number: .trackNumber, count: .trackCount, numberPath: \.trackNumber, countPath: \.trackCount)
                        indexRow("Disc Number", number: .discNumber, count: .discCount, numberPath: \.discNumber, countPath: \.discCount)
                        field("BPM", .bpm, \.bpm)
                    }

                    Toggle(isOn: compilationBinding) {
                        Text(compilationLabel)
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
        .task(id: items.map(\.id).joined(separator: "\u{1e}")) {
            await reload()
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var subtitle: String {
        if isMultiple {
            return "\(items.count) files"
        }
        return items.first?.name ?? ""
    }

    private var compilationLabel: String {
        if mixed.contains(.isCompilation) {
            "Album is a compilation of songs by various artists (Mixed)"
        } else {
            "Album is a compilation of songs by various artists"
        }
    }

    private var compilationBinding: Binding<Bool> {
        Binding(
            get: { draft.isCompilation },
            set: { newValue in
                draft.isCompilation = newValue
                mixed.remove(.isCompilation)
            }
        )
    }

    private func field(
        _ label: String,
        _ tagField: AudioTagField,
        _ path: WritableKeyPath<AudioTags, String>,
        disabled: Bool = false
    ) -> some View {
        GridRow {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            TextField(placeholder(for: tagField), text: stringBinding(tagField, path))
                .textFieldStyle(.roundedBorder)
                .disabled(fieldsDisabled || disabled)
                .gridColumnAlignment(.leading)
        }
    }

    private func indexRow(
        _ label: String,
        number: AudioTagField,
        count: AudioTagField,
        numberPath: WritableKeyPath<AudioTags, String>,
        countPath: WritableKeyPath<AudioTags, String>
    ) -> some View {
        GridRow {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            HStack(spacing: 8) {
                TextField(placeholder(for: number), text: stringBinding(number, numberPath))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .disabled(fieldsDisabled)
                Text("of")
                    .foregroundStyle(.secondary)
                TextField(placeholder(for: count), text: stringBinding(count, countPath))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .disabled(fieldsDisabled)
                Spacer(minLength: 0)
            }
            .gridColumnAlignment(.leading)
        }
    }

    private func placeholder(for field: AudioTagField) -> String {
        mixed.contains(field) ? "Mixed" : ""
    }

    private func stringBinding(
        _ field: AudioTagField,
        _ path: WritableKeyPath<AudioTags, String>
    ) -> Binding<String> {
        Binding(
            get: { draft[keyPath: path] },
            set: { newValue in
                draft[keyPath: path] = newValue
                mixed.remove(field)
            }
        )
    }

    private func reload() async {
        isLoading = true
        saveError = nil
        let loaded = await loadTags()
        guard !Task.isCancelled else { return }
        let consensus = AudioTags.consensus(of: loaded)
        draft = consensus.values
        original = consensus.values
        mixed = consensus.mixed
        originalMixed = consensus.mixed
        isLoading = false
    }

    private func loadTags() async -> [AudioTags] {
        await withTaskGroup(of: (Int, AudioTags).self, returning: [AudioTags].self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    (index, await AudioTagService.load(from: item.url))
                }
            }
            var ordered = Array(repeating: AudioTags.empty, count: items.count)
            for await (index, tags) in group {
                ordered[index] = tags
            }
            return ordered
        }
    }

    private func apply() {
        let next = draft.normalized
        guard !isSaving, !isLoading else { return }

        if isMultiple {
            let fields = fieldsToApply(from: next)
            guard !fields.isEmpty else {
                dismiss()
                return
            }
            save(next, applying: fields)
            return
        }

        if next == original.normalized {
            dismiss()
            return
        }
        save(next, applying: nil)
    }

    /// Fields the user resolved or changed. Mixed fields that were left alone
    /// (and Name, which is locked) are omitted so each file keeps its own value.
    private func fieldsToApply(from next: AudioTags) -> Set<AudioTagField> {
        var fields: Set<AudioTagField> = []
        for field in AudioTagField.allCases where field != .title {
            if mixed.contains(field) { continue }
            if originalMixed.contains(field) {
                fields.insert(field)
                continue
            }
            if let path = field.stringKeyPath {
                if next[keyPath: path] != original.normalized[keyPath: path] {
                    fields.insert(field)
                }
            } else if field == .isCompilation, next.isCompilation != original.normalized.isCompilation {
                fields.insert(.isCompilation)
            }
        }
        return fields
    }

    private func save(_ tags: AudioTags, applying fields: Set<AudioTagField>?) {
        isSaving = true
        saveError = nil
        Task {
            do {
                try await model.saveAudioTags(tags, applying: fields, to: items)
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

//
//  FolderSidebar.swift
//  Flicksy
//

import SwiftUI

struct FolderSidebar: View {
    @Environment(BrowserModel.self) private var model
    @State private var confirmsClearingClipboard = false
    @State private var expandedFolderIDs: Set<MediaFolder.ID> = []
    @State private var editor: SidebarEditor?

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedSource) {
            Section("Library") {
                Label("Favorites", systemImage: "star.fill").tag(BrowserSource.favorites)
                clipboardRow.tag(BrowserSource.clipboard)
                ForEach(StandardBrowserFolder.allCases, id: \.self) { folder in
                    Label(folder.title, systemImage: folder.systemImage)
                        .tag(BrowserSource.standardFolder(folder))
                }
            }

            Section("Collections") {
                if model.collections.isEmpty {
                    Text("No collections").foregroundStyle(.tertiary)
                } else {
                    ForEach(model.collections) { collection in
                        countRow(collection.name, systemImage: "rectangle.stack.badge.play", count: collection.itemCount)
                            .tag(BrowserSource.collection(collection.id))
                            .dropDestination(for: URL.self) { urls, _ in
                                model.addURLs(urls, to: collection)
                            }
                            .contextMenu {
                                Button("Rename…") { editor = .collection(collection) }
                                Button("Delete Collection", role: .destructive) { model.deleteCollection(collection) }
                            }
                    }
                }
            }

            Section("Tags") {
                if model.tags.isEmpty {
                    Text("No tags").foregroundStyle(.tertiary)
                } else {
                    ForEach(model.tags) { tag in
                        HStack(spacing: 8) {
                            Circle().fill(tag.color.color).frame(width: 9, height: 9).accessibilityHidden(true)
                            Text(tag.name)
                            Spacer()
                            count(tag.itemCount)
                        }
                        .tag(BrowserSource.tag(tag.id))
                        .contextMenu {
                            Button("Edit Tag…") { editor = .tag(tag) }
                            Button("Delete Tag", role: .destructive) { model.deleteTag(tag) }
                        }
                    }
                }
            }

            Section("Folders") {
                if model.rootTrees.isEmpty {
                    Text("No folders added").foregroundStyle(.tertiary)
                } else {
                    ForEach(model.rootTrees) { root in
                        FolderTreeRow(folder: root, expandedFolderIDs: $expandedFolderIDs)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { addBar }
        .sheet(item: $editor) { editor in
            switch editor {
            case .newCollection:
                CollectionEditor(title: "New Collection", initialName: "") { model.createCollection(name: $0) }
            case .collection(let collection):
                CollectionEditor(title: "Rename Collection", initialName: collection.name) {
                    model.renameCollection(collection, to: $0)
                }
            case .newTag:
                TagEditor(title: "New Tag", initialName: "", initialColor: .gray) { name, color in
                    model.createTag(name: name, color: color)
                }
            case .tag(let tag):
                TagEditor(title: "Edit Tag", initialName: tag.name, initialColor: tag.color) { name, color in
                    model.updateTag(tag, name: name, color: color)
                }
            }
        }
        .alert(
            "Merge Tags?",
            isPresented: Binding(
                get: { model.pendingTagMerge != nil },
                set: { if !$0 { model.pendingTagMerge = nil } }
            )
        ) {
            Button("Merge") { model.confirmPendingTagMerge() }
            Button("Cancel", role: .cancel) { model.pendingTagMerge = nil }
        } message: {
            if let pending = model.pendingTagMerge {
                Text("A tag named \"\(pending.name)\" already exists. Merging moves everything tagged \"\(pending.tag.name)\" onto \"\(pending.name)\" and removes \"\(pending.tag.name)\".")
            }
        }
        .alert("Clear Clipboard History?", isPresented: $confirmsClearingClipboard) {
            Button("Clear History", role: .destructive) { model.clearClipboardHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Flicksy's saved clipboard image copies. It does not delete their original files.")
        }
    }

    private func countRow(_ title: String, systemImage: String, count value: Int) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
            Spacer()
            count(value)
        }
    }

    private func count(_ value: Int) -> some View {
        Text(value, format: .number)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var clipboardRow: some View {
        HStack(spacing: 8) {
            Label("Clipboard", systemImage: "clipboard")
            Spacer()
            if model.clipboardItemCount > 0 { count(model.clipboardItemCount) }
        }
        .contextMenu {
            Button("Clear Clipboard History", role: .destructive) { confirmsClearingClipboard = true }
                .disabled(model.clipboardItemCount == 0)
        }
    }

    private var addBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 4) {
                Menu {
                    Button("New Collection…") { editor = .newCollection }
                    Button("New Tag…") { editor = .newTag }
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("New Collection or Tag")

                Button { model.addRootFolder() } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)

                Spacer()
                if model.isIndexingLibrary { ProgressView().controlSize(.small).help("Updating library") }
            }
            .padding(8)
        }
        .background(.bar)
    }
}

private enum SidebarEditor: Identifiable {
    case newCollection
    case collection(MediaCollection)
    case newTag
    case tag(LibraryTag)

    var id: String {
        switch self {
        case .newCollection: "new-collection"
        case .collection(let value): "collection-\(value.id)"
        case .newTag: "new-tag"
        case .tag(let value): "tag-\(value.id)"
        }
    }
}

struct CollectionEditor: View {
    let title: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Collection name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() { onSave(name); dismiss() }
}

struct TagEditor: View {
    let title: String
    let onSave: (String, LibraryTagColor) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: LibraryTagColor

    init(title: String, initialName: String, initialColor: LibraryTagColor, onSave: @escaping (String, LibraryTagColor) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _color = State(initialValue: initialColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Tag name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            Picker("Color", selection: $color) {
                ForEach(LibraryTagColor.allCases) { option in
                    HStack {
                        option.menuSwatch
                        Text(option.title)
                    }
                    .tag(option)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() { onSave(name, color); dismiss() }
}

private struct FolderTreeRow: View {
    @Environment(BrowserModel.self) private var model
    let folder: MediaFolder
    @Binding var expandedFolderIDs: Set<MediaFolder.ID>

    var body: some View {
        if folder.children.isEmpty {
            folderLabel.tag(BrowserSource.folder(folder.id))
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(folder.children) { child in
                    FolderTreeRow(folder: child, expandedFolderIDs: $expandedFolderIDs)
                }
            } label: {
                folderLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded {
                        model.selectedSource = .folder(folder.id)
                        withAnimation { toggleExpansion() }
                    })
            }
            .tag(BrowserSource.folder(folder.id))
        }
    }

    private var folderLabel: some View {
        Label(folder.name, systemImage: folder.isRoot ? "folder.badge.gearshape" : "folder")
            .contextMenu {
                if folder.isRoot {
                    Button("Remove Root Folder", role: .destructive) { model.removeRootFolder(id: folder.id) }
                }
            }
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expandedFolderIDs.contains(folder.id) },
            set: { expanded in
                if expanded { expandedFolderIDs.insert(folder.id) }
                else { expandedFolderIDs.remove(folder.id) }
            }
        )
    }

    private func toggleExpansion() {
        if expandedFolderIDs.contains(folder.id) { expandedFolderIDs.remove(folder.id) }
        else { expandedFolderIDs.insert(folder.id) }
    }
}


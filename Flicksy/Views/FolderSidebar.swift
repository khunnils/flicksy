//
//  FolderSidebar.swift
//  MediaBrowser
//

import SwiftUI

/// The smart, media-only folder tree (spec section 5).
struct FolderSidebar: View {
    @Environment(BrowserModel.self) private var model
    @State private var confirmsClearingClipboard = false
    @State private var expandedFolderIDs: Set<MediaFolder.ID> = []

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedSource) {
            Section("Library") {
                clipboardRow
                    .tag(BrowserSource.clipboard)

                ForEach(StandardBrowserFolder.allCases, id: \.self) { folder in
                    Label(folder.title, systemImage: folder.systemImage)
                        .tag(BrowserSource.standardFolder(folder))
                }
            }

            Section("Folders") {
                if model.rootTrees.isEmpty {
                    Text("No folders added")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(model.rootTrees) { root in
                        FolderTreeRow(
                            folder: root,
                            expandedFolderIDs: $expandedFolderIDs
                        )
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            addFolderBar
        }
        .alert("Clear Clipboard History?", isPresented: $confirmsClearingClipboard) {
            Button("Clear History", role: .destructive) {
                model.clearClipboardHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Flicksy's saved clipboard image copies. It does not delete their original files.")
        }
    }

    private var clipboardRow: some View {
        HStack(spacing: 8) {
            Label("Clipboard", systemImage: "clipboard")
            Spacer()
            if model.clipboardItemCount > 0 {
                Text(model.clipboardItemCount, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Clear Clipboard History", role: .destructive) {
                confirmsClearingClipboard = true
            }
            .disabled(model.clipboardItemCount == 0)
        }
    }

    private var addFolderBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                model.addRootFolder()
            } label: {
                Label("Add Folder…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .background(.bar)
    }
}

private struct FolderTreeRow: View {
    @Environment(BrowserModel.self) private var model

    let folder: MediaFolder
    @Binding var expandedFolderIDs: Set<MediaFolder.ID>

    var body: some View {
        if folder.children.isEmpty {
            folderLabel
                .tag(BrowserSource.folder(folder.id))
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(folder.children) { child in
                    FolderTreeRow(
                        folder: child,
                        expandedFolderIDs: $expandedFolderIDs
                    )
                }
            } label: {
                folderLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        TapGesture().onEnded {
                            model.selectedSource = .folder(folder.id)
                            withAnimation {
                                toggleExpansion()
                            }
                        }
                    )
            }
            .tag(BrowserSource.folder(folder.id))
        }
    }

    private var folderLabel: some View {
        Label(folder.name, systemImage: folder.isRoot ? "folder.badge.gearshape" : "folder")
            .contextMenu {
                if folder.isRoot {
                    Button("Remove Root Folder", role: .destructive) {
                        model.removeRootFolder(id: folder.id)
                    }
                }
            }
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expandedFolderIDs.contains(folder.id) },
            set: { expanded in
                if expanded {
                    expandedFolderIDs.insert(folder.id)
                } else {
                    expandedFolderIDs.remove(folder.id)
                }
            }
        )
    }

    private func toggleExpansion() {
        if expandedFolderIDs.contains(folder.id) {
            expandedFolderIDs.remove(folder.id)
        } else {
            expandedFolderIDs.insert(folder.id)
        }
    }
}

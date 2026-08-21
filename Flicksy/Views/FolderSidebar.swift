//
//  FolderSidebar.swift
//  MediaBrowser
//

import SwiftUI

/// The smart, media-only folder tree (spec section 5).
struct FolderSidebar: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Group {
            if model.rootTrees.isEmpty {
                emptyState
            } else {
                List(selection: $model.selectedFolderID) {
                    Section("Folders") {
                        ForEach(model.rootTrees) { root in
                            OutlineGroup(root, children: \.outlineChildren) { folder in
                                folderRow(folder)
                                    .tag(folder.id)
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            addFolderBar
        }
    }

    private func folderRow(_ folder: MediaFolder) -> some View {
        Label(folder.name, systemImage: folder.isRoot ? "folder.badge.gearshape" : "folder")
            .contextMenu {
                if folder.isRoot {
                    Button("Remove Root Folder", role: .destructive) {
                        model.removeRootFolder(id: folder.id)
                    }
                }
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Folders", systemImage: "folder.badge.plus")
        } description: {
            Text("Add a root folder to start browsing your media.")
        } actions: {
            Button("Add Folder…") {
                model.addRootFolder()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

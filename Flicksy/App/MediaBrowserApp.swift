//
//  MediaBrowserApp.swift
//  MediaBrowser
//
//  Created by Nils Hein on 21/8/26.
//

import SwiftUI

@main
struct MediaBrowserApp: App {
    @State private var model = BrowserModel()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Section {
                    Button("Zoom In") {
                        model.zoomIn()
                    }
                    .keyboardShortcut("+")
                    .disabled(
                        model.libraryTab != .visual
                            || model.thumbnailSize >= BrowserModel.maxThumbnailSize
                            || model.viewerItemID != nil
                    )

                    Button("Zoom Out") {
                        model.zoomOut()
                    }
                    .keyboardShortcut("-")
                    .disabled(
                        model.libraryTab != .visual
                            || model.thumbnailSize <= BrowserModel.minThumbnailSize
                            || model.viewerItemID != nil
                    )
                }
            }

            if model.isSearchFieldFocused {
                // Preserve the system pasteboard commands while editing the
                // search field so Command-A, Copy, and Paste stay native.
                CommandGroup(after: .pasteboard) {
                    findMediaCommand
                }
            } else {
                CommandGroup(replacing: .pasteboard) {
                    findMediaCommand

                    Divider()

                    Button("Select All") {
                        model.selectAll()
                    }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(model.orderedItems.isEmpty || model.viewerItemID != nil)

                    Button("Copy") {
                        model.copySelectedFiles()
                    }
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(model.selectedItemIDs.isEmpty && model.viewerItemID == nil)

                    Button("Copy Path") {
                        model.copyPath()
                    }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(model.selectedItemIDs.isEmpty && model.viewerItemID == nil)

                    Button("Reveal in Finder") {
                        model.revealInFinder()
                    }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.selectedItemIDs.isEmpty && model.viewerItemID == nil)

                    Button("Move to Trash") {
                        model.moveSelectedItemsToTrash()
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedItemIDs.isEmpty || model.viewerItemID != nil)
                }
            }
        }
    }

    private var findMediaCommand: some View {
        Button("Find Media") {
            model.isSearchPresented = true
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(model.selectedFolderID == nil || model.viewerItemID != nil)
    }
}

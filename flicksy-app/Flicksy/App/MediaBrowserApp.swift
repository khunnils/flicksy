//
//  MediaBrowserApp.swift
//  MediaBrowser
//
//  Created by Nils Hein on 21/8/26.
//

import SwiftUI

@main
struct FlicksyApp: App {
    @State private var model = BrowserModel()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
        }
        .commands {
            AboutCommands()
            GetInfoCommands(model: model)

            CommandGroup(after: .toolbar) {
                Section {
                    Button("Cycle Library View") {
                        model.toggleLibraryTab()
                    }
                    .keyboardShortcut(.tab, modifiers: [.control])
                    .disabled(model.viewerItemID != nil)

                    Button("Organize…") {
                        model.isOrganizePresented = true
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!model.canOrganizeSelection || model.viewerItemID != nil)

                    Divider()

                    Button("Zoom In") {
                        if model.isViewingImage {
                            model.zoomViewerImageIn()
                        } else {
                            model.zoomIn()
                        }
                    }
                    .keyboardShortcut("+")
                    .disabled(
                        model.isViewingImage
                            ? !model.canZoomViewerImageIn
                            : (model.libraryTab != .visual
                                || model.thumbnailSize >= BrowserModel.maxThumbnailSize
                                || model.viewerItemID != nil)
                    )

                    Button("Zoom Out") {
                        if model.isViewingImage {
                            model.zoomViewerImageOut()
                        } else {
                            model.zoomOut()
                        }
                    }
                    .keyboardShortcut("-")
                    .disabled(
                        model.isViewingImage
                            ? !model.canZoomViewerImageOut
                            : (model.libraryTab != .visual
                                || model.thumbnailSize <= BrowserModel.minThumbnailSize
                                || model.viewerItemID != nil)
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

                    Button("Paste") {
                        model.pasteFiles()
                    }
                    .keyboardShortcut("v", modifiers: .command)
                    .disabled(!model.canPasteFiles || model.viewerItemID != nil)

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
                        model.moveSelectedFilesToTrashExplicitly()
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedItemIDs.isEmpty || model.viewerItemID != nil)
                }
            }
        }

        Window("About Flicksy", id: AboutView.windowID) {
            AboutView()
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)

        WindowGroup("Info", id: MediaInfoView.windowID, for: String.self) { $itemID in
            if let itemID, let item = model.mediaItemForInfo(id: itemID) {
                MediaInfoView(item: item)
                    .environment(model)
            } else {
                ContentUnavailableView("File Unavailable", systemImage: "questionmark.folder")
                    .frame(width: 440, height: 560)
            }
        }
        .defaultSize(width: 440, height: 560)
        .windowResizability(.contentSize)
    }

    private var findMediaCommand: some View {
        Button("Find Media") {
            model.isSearchPresented = true
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(!model.hasSelectedSource || model.viewerItemID != nil)
    }
}

private struct GetInfoCommands: Commands {
    let model: BrowserModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Get Info") {
                guard let item = model.getInfoTarget else { return }
                model.registerInfoItem(item)
                openWindow(id: MediaInfoView.windowID, value: item.id)
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(model.getInfoTarget == nil)
        }
    }
}

private struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Flicksy") {
                openWindow(id: AboutView.windowID)
            }
        }
    }
}

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
                    .disabled(model.thumbnailSize >= BrowserModel.maxThumbnailSize)

                    Button("Zoom Out") {
                        model.zoomOut()
                    }
                    .keyboardShortcut("-")
                    .disabled(model.thumbnailSize <= BrowserModel.minThumbnailSize)
                }
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Select All") {
                    model.selectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(model.orderedItems.isEmpty || model.viewerItemID != nil)

                Button("Move to Trash") {
                    model.moveSelectedItemsToTrash()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedItemIDs.isEmpty || model.viewerItemID != nil)
            }
        }
    }
}

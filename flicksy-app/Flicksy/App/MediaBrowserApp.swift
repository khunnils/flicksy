//
//  MediaBrowserApp.swift
//  MediaBrowser
//
//  Created by Nils Hein on 21/8/26.
//

import SwiftUI

@main
struct FlicksyApp: App {
    @State private var model: BrowserModel?
    @State private var access = AccessController()
    @State private var updater = UpdateController()

    var body: some Scene {
        WindowGroup {
            FlicksyRootView(browserModel: $model)
                .environment(access)
        }
        .commands {
            AboutCommands(access: access, updater: updater)
            if let model {
                GetInfoCommands(model: model)

                CommandGroup(after: .help) {
                    Button("Welcome to Flicksy…") {
                        model.presentWelcome()
                    }
                    .disabled(
                        model.isWelcomePresented
                            || model.editAudioTagsRequest != nil
                            || model.organizationEditorRequest != nil
                    )

                    Divider()

                    Button("Keyboard Shortcuts…") {
                        model.presentShortcutsHelp()
                    }
                    .keyboardShortcut("/", modifiers: .command)
                }

                CommandGroup(after: .toolbar) {
                    Section {
                    Button("Command Palette…") {
                        model.toggleCommandPalette()
                    }
                    .keyboardShortcut("k", modifiers: .command)

                    Button("Jump to…") {
                        model.presentQuickGoto()
                    }
                    .keyboardShortcut("j", modifiers: .command)
                    .disabled(model.viewerItemID != nil)

                    Divider()

                    Button("All") {
                        model.selectLibraryTab(.all)
                    }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(model.viewerItemID != nil)

                    Button("Images & Video") {
                        model.selectLibraryTab(.visual)
                    }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(model.viewerItemID != nil)

                    Button("Audio") {
                        model.selectLibraryTab(.audio)
                    }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(model.viewerItemID != nil || model.isClipboardSelected)

                    Button("Jump to Start") {
                        model.requestAudioSeek(.start)
                    }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!model.canControlInspectorAudio)

                    Button("Rewind") {
                        model.requestAudioSeek(.rewind)
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!model.canControlInspectorAudio)

                    Button("Forward") {
                        model.requestAudioSeek(.forward)
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!model.canControlInspectorAudio)

                    Button("Jump to End") {
                        model.requestAudioSeek(.end)
                    }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(!model.canControlInspectorAudio)

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

                if model.isTextFieldFocused {
                    // Preserve the system pasteboard commands while editing the
                    // search or Jump to field so text shortcuts stay native.
                    CommandGroup(after: .pasteboard) {
                        findMediaCommand(model: model)
                    }
                } else {
                    CommandGroup(replacing: .pasteboard) {
                        findMediaCommand(model: model)

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
        }

        Window("About Flicksy", id: AboutView.windowID) {
            AboutView(access: access)
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)

        Window("Flicksy License", id: LicenseView.windowID) {
            LicenseView()
                .environment(access)
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)

        WindowGroup("Info", id: MediaInfoView.windowID, for: String.self) { $itemID in
            if let model, let itemID, let item = model.mediaItemForInfo(id: itemID) {
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

    private func findMediaCommand(model: BrowserModel) -> some View {
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

            Button("Edit Meta Tags…") {
                model.presentAudioTagsEditor()
            }
            .disabled(model.editAudioTagsTargets.isEmpty)
        }
    }
}

private struct AboutCommands: Commands {
    let access: AccessController
    let updater: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Flicksy") {
                openWindow(id: AboutView.windowID)
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Flicksy License…") {
                openWindow(id: LicenseView.windowID)
            }

#if DIRECT_DISTRIBUTION
            if access.state != .licensed {
                Button("Buy Flicksy…") {
                    Task { await access.purchase() }
                }
            }
#endif

#if APP_STORE_DISTRIBUTION
            Button("Verify App Store Purchase") {
                Task { await access.restore() }
            }
#endif

#if DIRECT_DISTRIBUTION
            Divider()
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
#endif
        }
    }
}

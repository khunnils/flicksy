//
//  MediaBrowserApp.swift
//  MediaBrowser
//
//  Created by Nils Hein on 21/8/26.
//

import AppKit
import SwiftUI

@main
struct FlicksyApp: App {
    @State private var access = AccessController()
    @State private var updater = UpdateController()

    init() {
        AppAnalytics.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            FlicksyRootView()
                .environment(access)
                .environment(SharedLibraryServices.shared)
        }
        .commands {
            AboutCommands(access: access, updater: updater)
            CommandGroup(after: .help) {
                Button("Flicksy Help") {
                    NSWorkspace.shared.open(flicksyHelpURL)
                }
            }
            BrowserCommands()
        }

        Settings {
            AnalyticsSettingsView()
        }

        Window("About Flicksy", id: AboutView.windowID) {
            AboutView(access: access)
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)

        Window("Flicksy Access", id: LicenseView.windowID) {
            LicenseView()
                .environment(access)
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)

        WindowGroup("Info", id: MediaInfoView.windowID, for: MediaInfoWindowRequest.self) { $request in
            MediaInfoWindowRoot(request: request)
                .environment(SharedLibraryServices.shared)
        }
        .defaultSize(width: 440, height: 560)
        .windowResizability(.contentSize)
    }

    private var flicksyHelpURL: URL {
        return URL(string: "https://flicksy.me/docs")!
    }
}

private struct BrowserCommands: Commands {
    @FocusedValue(\.browserModel) private var model

    var body: some Commands {
        if let model {
            GetInfoCommands()
            CommandGroup(after: .help) {
                Button("Welcome to Flicksy…") { model.presentWelcome() }
                    .disabled(model.isWelcomePresented || model.editAudioTagsRequest != nil || model.organizationEditorRequest != nil)
                Divider()
                Button("Keyboard Shortcuts…") { model.presentShortcutsHelp() }
                    .keyboardShortcut("/", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Section {
                    Button("Command Palette…") { model.toggleCommandPalette() }
                        .keyboardShortcut("k", modifiers: .command)
                    Button("Jump to…") { model.presentQuickGoto() }
                        .keyboardShortcut("j", modifiers: .command)
                        .disabled(model.viewerItemID != nil)
                    Divider()
                    Button("All") { model.selectLibraryTab(.all) }
                        .keyboardShortcut("1", modifiers: .command)
                        .disabled(model.viewerItemID != nil)
                    Button("Images & Video") { model.selectLibraryTab(.visual) }
                        .keyboardShortcut("2", modifiers: .command)
                        .disabled(model.viewerItemID != nil)
                    Button("Audio") { model.selectLibraryTab(.audio) }
                        .keyboardShortcut("3", modifiers: .command)
                        .disabled(model.viewerItemID != nil || model.isClipboardSelected)
                    audioSeekMenuItem(
                        "Jump to Start",
                        enabled: model.canControlInspectorAudio,
                        shortcut: .leftArrow,
                        modifiers: [.command, .shift]
                    ) {
                        model.requestAudioSeek(.start)
                    }
                    audioSeekMenuItem(
                        "Rewind",
                        enabled: model.canControlInspectorAudio,
                        shortcut: .leftArrow,
                        modifiers: []
                    ) {
                        model.requestAudioSeek(.rewind)
                    }
                    audioSeekMenuItem(
                        "Forward",
                        enabled: model.canControlInspectorAudio,
                        shortcut: .rightArrow,
                        modifiers: []
                    ) {
                        model.requestAudioSeek(.forward)
                    }
                    audioSeekMenuItem(
                        "Jump to End",
                        enabled: model.canControlInspectorAudio,
                        shortcut: .rightArrow,
                        modifiers: [.command, .shift]
                    ) {
                        model.requestAudioSeek(.end)
                    }
                    browserFocusMenuItem(
                        "Move Focus Left",
                        enabled: model.canMoveBrowserFocus,
                        shortcut: .leftArrow,
                        modifiers: .command
                    ) {
                        model.moveFocus(.left, columns: model.keyboardNavigationColumns)
                    }
                    browserFocusMenuItem(
                        "Move Focus Right",
                        enabled: model.canMoveBrowserFocus,
                        shortcut: .rightArrow,
                        modifiers: .command
                    ) {
                        model.moveFocus(.right, columns: model.keyboardNavigationColumns)
                    }
                    browserFocusMenuItem(
                        "Move Focus Up",
                        enabled: model.canMoveBrowserFocus,
                        shortcut: .upArrow,
                        modifiers: .command
                    ) {
                        model.moveFocus(.up, columns: model.keyboardNavigationColumns)
                    }
                    browserFocusMenuItem(
                        "Move Focus Down",
                        enabled: model.canMoveBrowserFocus,
                        shortcut: .downArrow,
                        modifiers: .command
                    ) {
                        model.moveFocus(.down, columns: model.keyboardNavigationColumns)
                    }
                    browserFocusMenuItem(
                        "Toggle Focused Item",
                        enabled: model.canMoveBrowserFocus && model.focusedItemID != nil,
                        shortcut: .return,
                        modifiers: .command
                    ) {
                        model.toggleFocusedItemSelection()
                    }
                    Button("Organize…") { model.isOrganizePresented = true }
                        .keyboardShortcut("t", modifiers: .command)
                        .disabled(!model.canOrganizeSelection || model.viewerItemID != nil)
                    Divider()
                    Button("Zoom In") {
                        if model.isViewingImage { model.zoomViewerImageIn() } else { model.zoomIn() }
                    }
                    .keyboardShortcut("+")
                    .disabled(model.isViewingImage ? !model.canZoomViewerImageIn : (model.libraryTab != .visual || model.thumbnailSize >= BrowserModel.maxThumbnailSize || model.viewerItemID != nil))
                    Button("Zoom Out") {
                        if model.isViewingImage { model.zoomViewerImageOut() } else { model.zoomOut() }
                    }
                    .keyboardShortcut("-")
                    .disabled(model.isViewingImage ? !model.canZoomViewerImageOut : (model.libraryTab != .visual || model.thumbnailSize <= BrowserModel.minThumbnailSize || model.viewerItemID != nil))
                }
            }
            if model.isTextFieldFocused {
                CommandGroup(after: .pasteboard) { findMediaCommand(model: model) }
            } else {
                CommandGroup(replacing: .pasteboard) {
                    findMediaCommand(model: model)
                    Divider()
                    Button("Select All") { model.selectAll() }
                        .keyboardShortcut("a", modifiers: .command)
                        .disabled(model.orderedItems.isEmpty || model.viewerItemID != nil)
                    Button("Copy") { model.copySelectedFiles() }
                        .keyboardShortcut("c", modifiers: .command)
                        .disabled(model.selectedItemIDs.isEmpty && model.viewerItemID == nil)
                    Button("Paste") { model.pasteFiles() }
                        .keyboardShortcut("v", modifiers: .command)
                        .disabled(!model.canPasteFiles || model.viewerItemID != nil)
                    Button("Copy Path") { model.copyPath() }
                        .keyboardShortcut("c", modifiers: [.command, .option])
                        .disabled(model.selectedItemIDs.isEmpty && model.viewerItemID == nil)
                    Button("Reveal in Finder") { model.revealInFinder() }
                        .keyboardShortcut("r", modifiers: [.command, .option])
                        .disabled(model.selectedItemIDs.isEmpty && model.viewerItemID == nil)
                    Button("Move to Trash") { model.moveSelectedFilesToTrashExplicitly() }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(model.selectedItemIDs.isEmpty || model.viewerItemID != nil)
                }
            }
        }
    }

    private func findMediaCommand(model: BrowserModel) -> some View {
        Button("Find Media") { model.isSearchPresented = true }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!model.hasSelectedSource || model.viewerItemID != nil)
    }

    /// Disabled menu key equivalents still swallow the event. Only attach the
    /// shortcut while the command can run.
    @ViewBuilder
    private func audioSeekMenuItem(
        _ title: String,
        enabled: Bool,
        shortcut: KeyEquivalent,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        browserFocusMenuItem(
            title,
            enabled: enabled,
            shortcut: shortcut,
            modifiers: modifiers,
            action: action
        )
    }

    @ViewBuilder
    private func browserFocusMenuItem(
        _ title: String,
        enabled: Bool,
        shortcut: KeyEquivalent,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        if enabled {
            Button(title, action: action)
                .keyboardShortcut(shortcut, modifiers: modifiers)
        } else {
            Button(title, action: action)
                .disabled(true)
        }
    }
}

private struct GetInfoCommands: Commands {
    @FocusedValue(\.browserModel) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Get Info") {
                guard let model, let item = model.getInfoTarget else { return }
                openWindow(id: MediaInfoView.windowID, value: model.registerInfoItem(item))
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(model?.getInfoTarget == nil)

            Button("Edit Meta Tags…") {
                model?.presentAudioTagsEditor()
            }
            .disabled(model?.editAudioTagsTargets.isEmpty ?? true)
        }
    }
}

private struct MediaInfoWindowRoot: View {
    let request: MediaInfoWindowRequest?
    @Environment(SharedLibraryServices.self) private var services

    var body: some View {
        if let request,
           let model = services.model(for: request.sessionID),
           let item = model.mediaItemForInfo(id: request.itemID) {
            MediaInfoView(item: item)
                .environment(model)
        } else {
            ContentUnavailableView("File Unavailable", systemImage: "questionmark.folder")
                .frame(width: 440, height: 560)
        }
    }
}

private struct BrowserModelFocusedValueKey: FocusedValueKey {
    typealias Value = BrowserModel
}

extension FocusedValues {
    var browserModel: BrowserModel? {
        get { self[BrowserModelFocusedValueKey.self] }
        set { self[BrowserModelFocusedValueKey.self] = newValue }
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
            Button("Flicksy Access…") {
                openWindow(id: LicenseView.windowID)
            }

#if DIRECT_DISTRIBUTION
            if access.state != .licensed {
                Button("View on App Store") {
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

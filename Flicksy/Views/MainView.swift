//
//  MainView.swift
//  MediaBrowser
//

import SwiftUI

/// Top-level two-pane layout (spec section 3).
struct MainView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            FolderSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            MediaBrowserView()
                .navigationTitle("Media Browser")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        GridSizePicker(columns: $model.gridColumns)
                    }
                }
        }
        .task {
            model.restore()
        }
        .alert(
            "Folder Problem",
            isPresented: Binding(
                get: { model.loadError != nil },
                set: { if !$0 { model.loadError = nil } }
            )
        ) {
            Button("Add Folder…") { model.addRootFolder() }
            Button("Dismiss", role: .cancel) { model.loadError = nil }
        } message: {
            Text(model.loadError ?? "")
        }
    }
}

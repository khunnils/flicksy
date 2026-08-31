//
//  SortControl.swift
//  MediaBrowser
//

import SwiftUI

/// Top-level sort menu. The same key and direction apply to both library tabs.
struct SortControl: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Menu {
            Picker("Sort By", selection: $model.sortKey) {
                ForEach(MediaSortKey.allCases.filter { $0 != .manual || model.isCollectionSelected }) { key in
                    Text(key.title).tag(key)
                }
            }

            Divider()

            Picker("Order", selection: $model.sortAscending) {
                Text(model.sortKey.ascendingLabel).tag(true)
                Text(model.sortKey.descendingLabel).tag(false)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort by \(model.sortKey.title)")
        .accessibilityLabel("Sort")
    }
}

/// All, Images & Video, and Audio, shown as a native segmented tab control.
struct LibraryTabPicker: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Picker("Library", selection: $model.libraryTab) {
            ForEach(MediaLibraryTab.allCases) { tab in
                Image(systemName: tab.systemImage)
                    .accessibilityLabel(tab.title)
                    .help(tab.title)
                    .tag(tab)
                    .disabled(model.isClipboardSelected && tab == .audio)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Switch library view (⌘1 All, ⌘2 Images & Video, ⌘3 Audio)")
        .accessibilityLabel("Library")
        .frame(width: 138)
    }
}

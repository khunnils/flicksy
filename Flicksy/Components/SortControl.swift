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
                ForEach(MediaSortKey.allCases) { key in
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

/// List or waveform layout, shown while the Audio tab is active.
struct AudioViewModeControl: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Picker("Audio View", selection: $model.audioViewMode) {
            Image(systemName: "list.bullet")
                .accessibilityLabel("List View")
                .tag(AudioViewMode.list)
            Image(systemName: "waveform")
                .accessibilityLabel("Waveform View")
                .tag(AudioViewMode.waveforms)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 76)
        .help("Audio view")
    }
}

/// Images & Video vs Audio, shown as a native segmented tab control.
struct LibraryTabPicker: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Picker("Library", selection: $model.libraryTab) {
            ForEach(MediaLibraryTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Switch between Images & Video and Audio")
        .accessibilityLabel("Library")
        .frame(minWidth: 220)
    }
}

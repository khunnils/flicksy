//
//  SortControl.swift
//  MediaBrowser
//

import AppKit
import SwiftUI

/// Top-level sort menu. The same key and direction apply to both library tabs.
struct SortControl: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        Menu {
            if model.isCollectionSelected {
                sortMenuItem(.manual)
            }
            sortMenuItem(.name)
            sortMenuItem(.kind)
            sortMenuItem(.added)
            sortMenuItem(.modified)
            sortMenuItem(.duration)
            sortMenuItem(.dimensions)
            sortMenuItem(.bitRate)
            sortMenuItem(.sampleRate)
            sortMenuItem(.channels)
            sortMenuItem(.size)

            Divider()

            Button {
                model.sortAscending = true
            } label: {
                if model.sortAscending {
                    Label(model.sortKey.ascendingLabel, systemImage: "checkmark")
                } else {
                    Text(model.sortKey.ascendingLabel)
                }
            }
            Button {
                model.sortAscending = false
            } label: {
                if !model.sortAscending {
                    Label(model.sortKey.descendingLabel, systemImage: "checkmark")
                } else {
                    Text(model.sortKey.descendingLabel)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort by \(model.sortKey.title)")
        .accessibilityLabel("Sort")
    }

    private func sortMenuItem(_ key: MediaSortKey) -> some View {
        Button {
            model.sortKey = key
        } label: {
            if model.sortKey == key {
                Label(key.title, systemImage: "checkmark")
            } else {
                Text(key.title)
            }
        }
    }
}

/// All, Images & Video, and Audio, shown as a native segmented tab control.
///
/// Built on `NSSegmentedControl` so individual segments can be disabled. SwiftUI
/// pickers still deliver clicks on `.disabled` tags.
struct LibraryTabPicker: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        LibraryTabSegmentedControl(
            selected: model.libraryTab,
            availability: MediaLibraryTab.allCases.map(model.isLibraryTabAvailable),
            onSelect: { tab in
                model.selectLibraryTab(tab)
                return model.libraryTab
            }
        )
        .frame(width: 138)
        .accessibilityLabel("Library")
    }
}

private struct LibraryTabSegmentedControl: NSViewRepresentable {
    var selected: MediaLibraryTab
    var availability: [Bool]
    var onSelect: (MediaLibraryTab) -> MediaLibraryTab

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let tabs = MediaLibraryTab.allCases
        let images = tabs.map { tab in
            NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
                ?? NSImage()
        }
        let control = NSSegmentedControl(
            images: images,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentStyle = .rounded
        control.setAccessibilityLabel("Library")
        for (index, tab) in tabs.enumerated() {
            control.setToolTip(tab.help, forSegment: index)
            control.setWidth(46, forSegment: index)
        }
        apply(to: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.onSelect = onSelect
        apply(to: control)
    }

    private func apply(to control: NSSegmentedControl) {
        let tabs = MediaLibraryTab.allCases
        for (index, tab) in tabs.enumerated() {
            let isAvailable = index < availability.count ? availability[index] : true
            control.setEnabled(isAvailable, forSegment: index)
            control.setToolTip(tab.help, forSegment: index)
        }
        if let index = tabs.firstIndex(of: selected) {
            control.selectedSegment = index
        }
    }

    final class Coordinator: NSObject {
        var onSelect: (MediaLibraryTab) -> MediaLibraryTab

        init(onSelect: @escaping (MediaLibraryTab) -> MediaLibraryTab) {
            self.onSelect = onSelect
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let tabs = MediaLibraryTab.allCases
            let index = sender.selectedSegment
            guard index >= 0, index < tabs.count else { return }
            let selected = onSelect(tabs[index])
            if let selectedIndex = tabs.firstIndex(of: selected) {
                sender.selectedSegment = selectedIndex
            }
        }
    }
}

/// One list column in a sortable header. Display only; taps are handled by
/// `SortableListHeader` from the click’s x position so neighboring columns
/// cannot steal each other’s actions.
struct SortableListColumn {
    let title: String
    let sortKey: MediaSortKey
    let width: CGFloat
    var alignment: Alignment = .trailing
}

/// Maps a click in the header’s local coordinates to the column under that x.
struct ListSortHeaderLayout {
    var gutter: CGFloat
    var spacing: CGFloat
    var horizontalPadding: CGFloat
    var columns: [(key: MediaSortKey, width: CGFloat)]

    func sortKey(atX x: CGFloat) -> MediaSortKey? {
        var origin = horizontalPadding + gutter + spacing
        for (index, column) in columns.enumerated() {
            let hitWidth = column.width + (index == columns.count - 1 ? horizontalPadding : spacing)
            if x >= origin && x < origin + hitWidth {
                return column.key
            }
            origin += column.width + spacing
        }
        return nil
    }
}

/// Finder-style column titles. A single header tap is mapped to a column by x,
/// rather than giving each title its own button (those mix up actions on macOS).
struct SortableListHeader: View {
    let gutter: CGFloat
    let spacing: CGFloat
    let horizontalPadding: CGFloat
    let columns: [SortableListColumn]

    @Environment(BrowserModel.self) private var model

    private var layout: ListSortHeaderLayout {
        ListSortHeaderLayout(
            gutter: gutter,
            spacing: spacing,
            horizontalPadding: horizontalPadding,
            columns: columns.map { ($0.sortKey, $0.width) }
        )
    }

    var body: some View {
        HStack(spacing: spacing) {
            Color.clear.frame(width: gutter)
            ForEach(columns, id: \.sortKey) { column in
                columnTitle(column)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 7)
        .fixedSize(horizontal: true, vertical: true)
        .overlay {
            HeaderClickCatcher { location in
                if let key = layout.sortKey(atX: location.x) {
                    model.sortByColumn(key)
                }
            }
        }
    }

    private func columnTitle(_ column: SortableListColumn) -> some View {
        let isActive = model.sortKey == column.sortKey
        return HStack(spacing: 3) {
            if column.alignment == .trailing {
                Spacer(minLength: 0)
            }
            Text(column.title)
                .lineLimit(1)
            if isActive {
                Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            }
            if column.alignment == .leading {
                Spacer(minLength: 0)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .frame(width: column.width, alignment: column.alignment)
        .allowsHitTesting(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityLabel(column.title)
        .accessibilityValue(isActive ? (model.sortAscending ? "Sorted ascending" : "Sorted descending") : "")
        .accessibilityHint("Sort by \(column.title)")
        .accessibilityAction {
            model.sortByColumn(column.sortKey)
        }
    }
}

/// AppKit click target for the header. SwiftUI buttons and gestures in this
/// HStack were delivering a neighboring column’s action.
private struct HeaderClickCatcher: NSViewRepresentable {
    var onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> HeaderClickView {
        let view = HeaderClickView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: HeaderClickView, context: Context) {
        nsView.onClick = onClick
    }
}

private final class HeaderClickView: NSView {
    var onClick: ((CGPoint) -> Void)?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }
}

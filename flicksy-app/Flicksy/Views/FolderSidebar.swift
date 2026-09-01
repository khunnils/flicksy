//
//  FolderSidebar.swift
//  Flicksy
//

import AppKit
import SwiftUI

struct FolderSidebar: View {
    @Environment(BrowserModel.self) private var model
    @State private var expandedFolderIDs: Set<MediaFolder.ID> = []
    @State private var dropTargetCollectionID: MediaCollection.ID?
    @State private var dropTargetStandardFolder: StandardBrowserFolder?
    @State private var isFoldersDropTargeted = false

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedSource) {
            Section("Library") {
                Label("Favorites", systemImage: "star.fill")
                    .sidebarSource(.favorites, selected: model.selectedSource)
                clipboardRow
                    .sidebarSource(.clipboard, selected: model.selectedSource)
                ForEach(StandardBrowserFolder.allCases, id: \.self) { folder in
                    Label(folder.title, systemImage: folder.systemImage)
                        .sidebarSource(
                            .standardFolder(folder),
                            selected: model.selectedSource,
                            isDropTarget: dropTargetStandardFolder == folder
                        )
                        .dropDestination(for: URL.self) { urls, _ in
                            dropTargetStandardFolder = nil
                            return model.moveDraggedMedia(urls, into: folder)
                        } isTargeted: { isTargeted in
                            if isTargeted {
                                dropTargetStandardFolder = folder
                            } else if dropTargetStandardFolder == folder {
                                dropTargetStandardFolder = nil
                            }
                        }
                }
            }

            Section {
                if model.collections.isEmpty {
                    Text("No collections").foregroundStyle(.tertiary)
                } else {
                    ForEach(model.collections) { collection in
                        countRow(collection.name, systemImage: "rectangle.stack.badge.play", count: collection.itemCount)
                            .tag(BrowserSource.collection(collection.id))
                            .listRowBackground(
                                SidebarRowBackground(
                                    isSelected: model.selectedSource == .collection(collection.id),
                                    isDropTarget: dropTargetCollectionID == collection.id
                                )
                            )
                            .dropDestination(for: URL.self) { urls, _ in
                                dropTargetCollectionID = nil
                                return model.addURLs(urls, to: collection)
                            } isTargeted: { isTargeted in
                                if isTargeted {
                                    dropTargetCollectionID = collection.id
                                } else if dropTargetCollectionID == collection.id {
                                    dropTargetCollectionID = nil
                                }
                            }
                            .contextMenu {
                                Button("Rename…") { model.organizationEditorRequest = .editCollection(collection) }
                                Button("Delete Collection", role: .destructive) { model.deleteCollection(collection) }
                            }
                    }
                }
            } header: {
                organizationSectionHeader("Collections", help: "New Collection") {
                    model.organizationEditorRequest = .newCollection(addingSelection: false)
                }
            }

            Section {
                if model.tags.isEmpty {
                    Text("No tags").foregroundStyle(.tertiary)
                } else {
                    ForEach(model.tags) { tag in
                        HStack(spacing: 8) {
                            Circle().fill(tag.color.color).frame(width: 9, height: 9).accessibilityHidden(true)
                            Text(tag.name)
                            Spacer()
                            count(tag.itemCount)
                        }
                        .sidebarSource(.tag(tag.id), selected: model.selectedSource)
                        .contextMenu {
                            Button("Edit Tag…") { model.organizationEditorRequest = .editTag(tag) }
                            Button("Delete Tag", role: .destructive) { model.deleteTag(tag) }
                        }
                    }
                }
            } header: {
                organizationSectionHeader("Tags", help: "New Tag") {
                    model.organizationEditorRequest = .newTag(applyingSelection: false)
                }
            }

            Section {
                if model.rootTrees.isEmpty {
                    Text("No folders added").foregroundStyle(.tertiary)
                } else {
                    ForEach(model.rootTrees) { root in
                        FolderTreeRow(folder: root, expandedFolderIDs: $expandedFolderIDs)
                    }
                }
            } header: {
                Text("Folders")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .dropDestination(for: URL.self) { urls, _ in
                        model.addRootFolders(urls)
                    } isTargeted: { isFoldersDropTargeted = $0 }
                    .padding(.vertical, 3)
                    .background(
                        isFoldersDropTargeted
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear
                    )
            }
        }
        // Sidebar List ignores SwiftUI tint for selection, so we draw a grey
        // fill ourselves and suppress the system accent highlight underneath.
        .background(DisableSystemListSelectionHighlight())
        .safeAreaInset(edge: .bottom) { addBar }
        .alert(
            "Merge Tags?",
            isPresented: Binding(
                get: { model.pendingTagMerge != nil },
                set: { if !$0 { model.pendingTagMerge = nil } }
            )
        ) {
            Button("Merge") { model.confirmPendingTagMerge() }
            Button("Cancel", role: .cancel) { model.pendingTagMerge = nil }
        } message: {
            if let pending = model.pendingTagMerge {
                Text("A tag named \"\(pending.name)\" already exists. Merging moves everything tagged \"\(pending.tag.name)\" onto \"\(pending.name)\" and removes \"\(pending.tag.name)\".")
            }
        }
        .alert("Clear Clipboard History?", isPresented: $model.confirmsClearingClipboard) {
            Button("Clear History", role: .destructive) { model.clearClipboardHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Flicksy's saved clipboard image copies. It does not delete their original files.")
        }
    }

    private func countRow(_ title: String, systemImage: String, count value: Int) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
            Spacer()
            count(value)
        }
    }

    private func count(_ value: Int) -> some View {
        Text(value, format: .number)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func organizationSectionHeader(
        _ title: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(help)
            .help(help)
        }
    }

    private var clipboardRow: some View {
        HStack(spacing: 8) {
            Label("Clipboard", systemImage: "clipboard")
            Spacer()
            if model.clipboardItemCount > 0 { count(model.clipboardItemCount) }
        }
        .contextMenu {
            Button("Clear Clipboard History", role: .destructive) { model.confirmsClearingClipboard = true }
                .disabled(model.clipboardItemCount == 0)
        }
    }

    private var addBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button { model.addRootFolder() } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)

                Spacer()
                if model.isIndexingLibrary { ProgressView().controlSize(.small).help("Updating library") }
            }
            .padding(8)
        }
        .background(.bar)
    }
}


struct CollectionEditor: View {
    let title: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Collection name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() { onSave(name); dismiss() }
}

struct TagEditor: View {
    let title: String
    let onSave: (String, LibraryTagColor) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: LibraryTagColor

    init(title: String, initialName: String, initialColor: LibraryTagColor, onSave: @escaping (String, LibraryTagColor) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _color = State(initialValue: initialColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Tag name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            Picker("Color", selection: $color) {
                ForEach(LibraryTagColor.allCases) { option in
                    HStack {
                        option.menuSwatch
                        Text(option.title)
                    }
                    .tag(option)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() { onSave(name, color); dismiss() }
}

private struct FolderTreeRow: View {
    @Environment(BrowserModel.self) private var model
    let folder: MediaFolder
    @Binding var expandedFolderIDs: Set<MediaFolder.ID>
    @State private var isHovering = false
    @State private var isDropTargeted = false

    var body: some View {
        if folder.children.isEmpty {
            folderRow
                .sidebarSource(
                    .folder(folder.id),
                    selected: model.selectedSource,
                    isDropTarget: isDropTargeted
                )
                .listRowInsets(Self.rowInsets)
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(folder.children) { child in
                    FolderTreeRow(folder: child, expandedFolderIDs: $expandedFolderIDs)
                }
            } label: {
                folderRow(togglesExpansion: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sidebarSource(
                .folder(folder.id),
                selected: model.selectedSource,
                isDropTarget: isDropTargeted
            )
            .listRowInsets(Self.rowInsets)
        }
    }

    /// Slightly tighter trailing inset so the hide control sits inside the
    /// selection highlight instead of past its right edge.
    private static let rowInsets = EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 4)

    private var folderRow: some View {
        folderRow(togglesExpansion: false)
    }

    private func folderRow(togglesExpansion: Bool) -> some View {
        HStack(spacing: 4) {
            Group {
                if togglesExpansion {
                    folderName
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded {
                            model.selectedSource = .folder(folder.id)
                            withAnimation { toggleExpansion() }
                        })
                } else {
                    folderName
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !folder.isRoot {
                hideButton
            }
        }
        .onHover { isHovering = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            isDropTargeted = false
            return model.moveDraggedMedia(urls, into: folder.url)
        } isTargeted: { isDropTargeted = $0 }
        .contextMenu {
            Button("Reveal in Finder") { model.revealInFinder(folder) }
            Divider()
            if folder.isRoot {
                Button("Remove Root Folder", role: .destructive) { model.removeRootFolder(id: folder.id) }
                if model.hasHiddenSubfolders(under: folder) {
                    Button("Show Hidden Subfolders") { model.restoreHiddenSubfolders(under: folder) }
                }
            } else {
                Button("Hide Folder") { model.hideSubfolder(folder) }
            }
        }
    }

    private var folderName: some View {
        Label(folder.name, systemImage: folder.isRoot ? "folder.badge.gearshape" : "folder")
            .lineLimit(1)
    }

    private var hideButton: some View {
        Button {
            model.hideSubfolder(folder)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
        .help("Hide this folder from the library")
        .accessibilityLabel("Hide Folder")
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expandedFolderIDs.contains(folder.id) },
            set: { expanded in
                if expanded { expandedFolderIDs.insert(folder.id) }
                else { expandedFolderIDs.remove(folder.id) }
            }
        )
    }

    private func toggleExpansion() {
        if expandedFolderIDs.contains(folder.id) { expandedFolderIDs.remove(folder.id) }
        else { expandedFolderIDs.insert(folder.id) }
    }
}

// MARK: - Neutral sidebar selection

private extension View {
    func sidebarSource(
        _ source: BrowserSource,
        selected: BrowserSource?,
        isDropTarget: Bool = false
    ) -> some View {
        tag(source)
            .listRowBackground(SidebarRowBackground(
                isSelected: selected == source,
                isDropTarget: isDropTarget
            ))
    }
}

private struct SidebarRowBackground: View {
    let isSelected: Bool
    var isDropTarget: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fill)
            .padding(.horizontal, 8)
    }

    private var fill: Color {
        if isDropTarget { return Color.accentColor.opacity(0.2) }
        if isSelected { return Color.primary.opacity(0.1) }
        return .clear
    }
}

/// Sidebar `List` selection is drawn by AppKit's outline/table view, which
/// ignores SwiftUI `tint`. Clear that system highlight so our grey row
/// background is the only selection chrome.
///
/// The representable is installed via `.background`, so it sits beside the
/// scroll view rather than inside it — we have to search sibling descendants,
/// not only the superview chain. AppKit also restores emphasized (blue)
/// selection when the list is focused, so the suppression is re-applied on
/// window updates.
private struct DisableSystemListSelectionHighlight: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        HighlightFixerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HighlightFixerView)?.installAndApply()
    }

    private final class HighlightFixerView: NSView {
        private var updateObserver: NSObjectProtocol?
        private weak var observedWindow: NSWindow?
        private weak var trackedTableView: NSTableView?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            removeUpdateObserver()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installAndApply()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            installAndApply()
        }

        func installAndApply() {
            if observedWindow !== window {
                removeUpdateObserver()
                observedWindow = window
                if let window {
                    updateObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.didUpdateNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        self?.applyNeutralSelectionChrome()
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.applyNeutralSelectionChrome()
            }
        }

        private func removeUpdateObserver() {
            if let updateObserver {
                NotificationCenter.default.removeObserver(updateObserver)
                self.updateObserver = nil
            }
            observedWindow = nil
        }

        private func applyNeutralSelectionChrome() {
            let table = trackedTableView ?? Self.nearestTableView(from: self)
            guard let table else { return }
            trackedTableView = table

            if table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }

            // Focused lists mark selected rows emphasized (accent blue). Force
            // the unemphasized path so our grey `listRowBackground` remains.
            table.enumerateAvailableRowViews { rowView, _ in
                if rowView.isEmphasized {
                    rowView.isEmphasized = false
                }
            }
        }

        /// Walk up from the background host, searching each ancestor's subtree.
        /// The outline/table view is a sibling of this representable, not an
        /// ancestor, so a superview-only walk never finds it.
        private static func nearestTableView(from start: NSView) -> NSTableView? {
            var current: NSView? = start
            while let view = current {
                if let table = firstTableView(in: view) { return table }
                current = view.superview
            }
            return firstTableView(in: start.window?.contentView)
        }

        private static func firstTableView(in root: NSView?) -> NSTableView? {
            guard let root else { return nil }
            if let table = root as? NSTableView { return table }
            if let scroll = root as? NSScrollView, let table = scroll.documentView as? NSTableView {
                return table
            }
            for subview in root.subviews {
                if let table = firstTableView(in: subview) { return table }
            }
            return nil
        }
    }
}

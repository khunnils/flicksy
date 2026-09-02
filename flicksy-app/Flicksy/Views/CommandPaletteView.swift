//
//  CommandPaletteView.swift
//  Flicksy
//

import AppKit
import SwiftUI

private enum CommandPaletteAction: Hashable {
    case addRootFolder
    case jumpTo
    case manageTags
    case manageCollections
    case paste
    case clearClipboard
    case shortcuts
    case openSelection
    case compare
    case openWith
    case openWithApplication(OpenWithApplication)
    case getInfo
    case editMetaTags
    case toggleFavorite
    case selectionTags
    case setTag(LibraryTag, Bool)
    case selectionCollections
    case addToCollection(MediaCollection)
    case removeFromCollection
    case duplicate
    case rename
    case copy
    case copyPath
    case reveal
    case trash
    case newTag(Bool)
    case editTag(LibraryTag)
    case deleteTag(LibraryTag)
    case newCollection(Bool)
    case editCollection(MediaCollection)
    case deleteCollection(MediaCollection)
}

private enum CommandPalettePayload: Hashable {
    case action(CommandPaletteAction)
    case destination(BrowserDestination)
    case file(CommandPaletteFileLocation)
}

private struct CommandPaletteRow: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String?
    let systemImage: String
    var trailing: String?
    var destructive = false
    let keywords: [String]
    let payload: CommandPalettePayload

    func matchRank(for query: String) -> Int? {
        let query = BrowserDestination.normalized(query)
        guard !query.isEmpty else { return 3 }
        let title = BrowserDestination.normalized(title)
        let detail = BrowserDestination.normalized(detail ?? "")
        let keywords = BrowserDestination.normalized(keywords.joined(separator: " "))
        if title == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        if title.contains(query) { return 2 }
        if detail.contains(query) || keywords.contains(query) { return 3 }
        return nil
    }
}

private struct CommandPaletteSection: Identifiable {
    let id: String
    let title: String
    let rows: [CommandPaletteRow]
}

private enum CommandPaletteSelectionSource {
    case automatic
    case keyboard
    case pointer
}

struct CommandPaletteView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @FocusState private var queryFocused: Bool
    @State private var query = ""
    @State private var page: CommandPalettePage = .root
    @State private var selectedID: String?
    @State private var selectionSource: CommandPaletteSelectionSource = .automatic
    @State private var pointerLocationAtKeyboardSelection: NSPoint?

    private let panelShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.20)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                searchHeader
                Divider().opacity(0.6)
                results
            }
            .frame(maxWidth: .infinity, minHeight: 420, maxHeight: 640, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor), in: panelShape)
            .clipShape(panelShape)
            .overlay { panelShape.strokeBorder(.primary.opacity(0.09), lineWidth: 1) }
            .shadow(color: .black.opacity(0.24), radius: 30, y: 14)
            .padding(.horizontal, 32)
            .padding(.vertical, 44)
            .frame(maxWidth: 824)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .light)
        .ignoresSafeArea()
        .onAppear {
            model.isCommandPaletteFieldFocused = true
            selectFirstRow()
            focusQueryField()
        }
        .onDisappear { model.isCommandPaletteFieldFocused = false }
        .onChange(of: query) { selectFirstRow() }
        .onChange(of: page) {
            query = ""
            selectFirstRow()
            focusQueryField()
        }
        .onChange(of: model.commandPaletteSearchIndex != nil) { selectFirstRow() }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.escape) {
            navigateBackOrDismiss()
            return .handled
        }
        .onKeyPress(.return) {
            executeSelection()
            return .handled
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            if page != .root {
                Button(action: navigateBackOrDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 21))
                .focused($queryFocused)
                .onSubmit(executeSelection)

            if model.isLoadingCommandPaletteIndex, page == .root, !query.isEmpty {
                ProgressView().controlSize(.small)
            }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            } else if page == .root {
                Text("esc")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.09)) }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 68)
    }

    private var placeholder: String {
        switch page {
        case .root: "Type a command or search…"
        case .manageTags, .selectionTags: "Search tags…"
        case .manageCollections, .selectionCollections: "Search collections…"
        case .openWith: "Search applications…"
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sections.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
            .onChange(of: selectedID) { _, id in
                guard let id, selectionSource != .pointer else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    // With no anchor SwiftUI moves only enough to reveal a row,
                    // instead of recentering the list on every arrow press.
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private func sectionView(_ section: CommandPaletteSection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 6)

            ForEach(section.rows) { row in
                rowView(row).id(row.id)
            }
        }
    }

    private func rowView(_ row: CommandPaletteRow) -> some View {
        let selected = row.id == selectedID
        return Button { execute(row) } label: {
            HStack(spacing: 13) {
                Image(systemName: row.systemImage)
                    .font(.system(size: 16))
                    .foregroundStyle(row.destructive ? Color.red : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 16))
                        .foregroundStyle(row.destructive ? Color.red : Color.primary)
                        .lineLimit(1)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 12)
                if let trailing = row.trailing {
                    Text(trailing)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 26, minHeight: 24)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 5))
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.09)) }
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: row.detail == nil ? 48 : 56)
            .contentShape(Rectangle())
            .background(selected ? Color.primary.opacity(0.065) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .onContinuousHover { phase in
            guard case .active = phase else { return }

            let pointerLocation = NSEvent.mouseLocation
            if selectionSource == .keyboard,
               pointerLocation == pointerLocationAtKeyboardSelection {
                // Scrolling can put a new row under a stationary pointer. Do not
                // let that synthetic hover steal the keyboard selection.
                return
            }

            pointerLocationAtKeyboardSelection = nil
            selectionSource = .pointer
            selectedID = row.id
        }
    }

    private var sections: [CommandPaletteSection] {
        switch page {
        case .root: rootSections
        case .manageTags: nestedSections(rows: manageTagRows, title: "Tags")
        case .manageCollections: nestedSections(rows: manageCollectionRows, title: "Collections")
        case .selectionTags: nestedSections(rows: selectionTagRows, title: "Tags")
        case .selectionCollections: nestedSections(rows: selectionCollectionRows, title: "Collections")
        case .openWith: nestedSections(rows: openWithRows, title: "Applications")
        }
    }

    private var rootSections: [CommandPaletteSection] {
        let contextual = contextualCommands
        let general = generalCommands
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var result: [CommandPaletteSection] = []
            if !contextual.isEmpty {
                result.append(.init(id: "context", title: selectionSectionTitle, rows: contextual))
            }
            result.append(.init(id: "general", title: "General", rows: general))
            return result
        }

        var result: [CommandPaletteSection] = []
        let commandMatches = ranked(contextual + general)
        if !commandMatches.isEmpty {
            result.append(.init(id: "commands", title: "Commands", rows: commandMatches))
        }

        let destinationMatches = (model.commandPaletteSearchIndex?.destinations ?? model.browserDestinations)
            .compactMap { destination -> (BrowserDestination, Int)? in
                destination.matchRank(for: query).map { (destination, $0) }
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1
                    ? lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
                    : lhs.1 < rhs.1
            }
            .map { destinationRow($0.0) }
        if !destinationMatches.isEmpty {
            result.append(.init(id: "destinations", title: "Folders & Destinations", rows: destinationMatches))
        }

        let fileMatches = (model.commandPaletteSearchIndex?.files ?? [])
            .compactMap { location -> (CommandPaletteFileLocation, Int)? in
                location.matchRank(for: query).map { (location, $0) }
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                let name = lhs.0.item.name.localizedStandardCompare(rhs.0.item.name)
                if name != .orderedSame { return name == .orderedAscending }
                return lhs.0.locationTitle.localizedStandardCompare(rhs.0.locationTitle) == .orderedAscending
            }
            .map { fileRow($0.0) }
        if !fileMatches.isEmpty {
            result.append(.init(id: "files", title: "Files", rows: fileMatches))
        }
        return result
    }

    private var selectionSectionTitle: String {
        let count = model.commandPaletteSelectionItems.count
        return count == 1 ? "Selected Item" : "\(count) Selected Items"
    }

    private var contextualCommands: [CommandPaletteRow] {
        let items = model.commandPaletteSelectionItems
        guard !items.isEmpty else { return [] }
        let capabilities = CommandPaletteSelectionCapabilities(
            items: items,
            isClipboardSelected: model.isClipboardSelected,
            isCollectionSelected: model.isCollectionSelected
        )
        var rows: [CommandPaletteRow] = []

        if capabilities.canOpenSelection {
            let playsAudio = items.allSatisfy { $0.type == .audio }
            rows.append(command(
                id: "open-selection",
                title: playsAudio ? "Play Audio" : "Open Preview",
                icon: playsAudio ? "play.fill" : "eye",
                action: .openSelection,
                keywords: ["open", "preview", "play"]
            ))
        }

        if capabilities.canCompareImages {
            rows.append(command(
                id: "compare",
                title: "Compare Images",
                icon: "square.grid.2x2",
                trailing: "⇧Space",
                action: .compare,
                keywords: ["compare", "layout", "side by side"]
            ))
        }

        let applications = OpenWithApplicationsCache.shared.applications(for: items)
        if !applications.isEmpty {
            rows.append(command(id: "open-with", title: "Open With…", icon: "macwindow.on.rectangle", action: .openWith))
        }
        if capabilities.canGetInfo {
            rows.append(command(id: "get-info", title: "Get Info", icon: "info.circle", trailing: "⌘I", action: .getInfo))
        }
        if capabilities.canEditMetaTags {
            rows.append(command(id: "edit-meta", title: "Edit Meta Tags…", icon: "music.note.list", action: .editMetaTags))
        }
        if capabilities.canOrganize {
            let favorite = model.selectionIsAllFavorite()
            rows.append(command(
                id: "favorite",
                title: favorite ? "Remove from Favorites" : "Add to Favorites",
                icon: favorite ? "star.slash" : "star",
                action: .toggleFavorite
            ))
            rows.append(command(id: "selection-tags", title: "Tags…", icon: "tag", action: .selectionTags))
            rows.append(command(id: "selection-collections", title: "Add to Collection…", icon: "rectangle.stack.badge.plus", action: .selectionCollections))
            if capabilities.canRemoveFromCollection {
                rows.append(command(id: "remove-collection", title: "Remove from Collection", icon: "rectangle.stack.badge.minus", action: .removeFromCollection))
            }
        }
        if capabilities.canDuplicate {
            rows.append(command(id: "duplicate", title: "Duplicate", icon: "plus.square.on.square", action: .duplicate))
            if capabilities.canRename {
                rows.append(command(id: "rename", title: "Rename…", icon: "pencil", action: .rename))
            }
        }
        rows.append(command(id: "copy", title: "Copy", icon: "doc.on.doc", trailing: "⌘C", action: .copy))
        rows.append(command(id: "copy-path", title: "Copy Path", icon: "link", trailing: "⌘⌥C", action: .copyPath))
        rows.append(command(id: "reveal", title: "Reveal in Finder", icon: "folder", trailing: "⌘⌥R", action: .reveal))
        rows.append(command(
            id: "trash",
            title: model.isClipboardSelected ? "Remove from Clipboard History" : "Move to Trash",
            icon: "trash",
            trailing: "⌘⌫",
            action: .trash,
            destructive: true
        ))
        return rows
    }

    private var generalCommands: [CommandPaletteRow] {
        var rows = [
            command(id: "jump-to", title: "Jump to…", icon: "arrow.right.circle", trailing: "⌘J", action: .jumpTo, keywords: ["go to", "folder", "collection", "library"]),
            command(id: "add-root", title: "Add Root Folder…", icon: "folder.badge.plus", action: .addRootFolder, keywords: ["add folder", "library"]),
            command(id: "new-tag", title: "New Tag…", icon: "tag", action: .newTag(false), keywords: ["create tag", "add tag"]),
            command(id: "new-collection", title: "New Collection…", icon: "rectangle.stack.badge.plus", action: .newCollection(false), keywords: ["create collection", "add collection"]),
            command(id: "manage-tags", title: "Manage Tags…", icon: "tag", action: .manageTags),
            command(id: "manage-collections", title: "Manage Collections…", icon: "rectangle.stack", action: .manageCollections),
        ]
        if model.canPasteFiles {
            rows.append(command(id: "paste", title: "Paste into Current Folder", icon: "doc.on.clipboard", trailing: "⌘V", action: .paste))
        }
        if model.clipboardItemCount > 0 {
            rows.append(command(id: "clear-clipboard", title: "Clear Clipboard History…", icon: "clipboard", action: .clearClipboard, destructive: true))
        }
        rows.append(command(id: "shortcuts", title: "Keyboard Shortcuts…", icon: "keyboard", trailing: "⌘/", action: .shortcuts))
        return rows
    }

    private var manageTagRows: [CommandPaletteRow] {
        var rows = [command(id: "new-tag", title: "New Tag…", icon: "plus", action: .newTag(false))]
        for tag in model.tags {
            rows.append(command(id: "edit-tag-\(tag.id)", title: "Edit \(tag.name)…", detail: "Tag", icon: "pencil", action: .editTag(tag), keywords: [tag.name]))
            rows.append(command(id: "delete-tag-\(tag.id)", title: "Delete \(tag.name)", detail: "Tag", icon: "trash", action: .deleteTag(tag), destructive: true, keywords: [tag.name]))
        }
        return rows
    }

    private var manageCollectionRows: [CommandPaletteRow] {
        var rows = [command(id: "new-collection", title: "New Collection…", icon: "plus", action: .newCollection(false))]
        for collection in model.collections {
            rows.append(command(id: "edit-collection-\(collection.id)", title: "Rename \(collection.name)…", detail: "Collection", icon: "pencil", action: .editCollection(collection), keywords: [collection.name]))
            rows.append(command(id: "delete-collection-\(collection.id)", title: "Delete \(collection.name)", detail: "Collection", icon: "trash", action: .deleteCollection(collection), destructive: true, keywords: [collection.name]))
        }
        return rows
    }

    private var selectionTagRows: [CommandPaletteRow] {
        let items = model.commandPaletteSelectionItems
        var rows = [command(id: "new-selection-tag", title: "New Tag…", icon: "plus", action: .newTag(true))]
        for tag in model.tags {
            let applied = !items.isEmpty && items.allSatisfy { item in item.tags.contains(where: { $0.id == tag.id }) }
            rows.append(command(
                id: "toggle-tag-\(tag.id)",
                title: tag.name,
                detail: applied ? "Applied to all selected items" : nil,
                icon: applied ? "checkmark.circle.fill" : "circle",
                action: .setTag(tag, !applied),
                keywords: [tag.name]
            ))
        }
        return rows
    }

    private var selectionCollectionRows: [CommandPaletteRow] {
        var rows = [command(id: "new-selection-collection", title: "New Collection…", icon: "plus", action: .newCollection(true))]
        rows += model.collections.map { collection in
            command(
                id: "add-collection-\(collection.id)",
                title: collection.name,
                detail: "Add selected items",
                icon: "rectangle.stack.badge.plus",
                action: .addToCollection(collection),
                keywords: [collection.name]
            )
        }
        return rows
    }

    private var openWithRows: [CommandPaletteRow] {
        OpenWithApplicationsCache.shared.applications(for: model.commandPaletteSelectionItems).map { application in
            command(
                id: "open-app-\(application.id)",
                title: application.name,
                detail: "Application",
                icon: "app",
                action: .openWithApplication(application),
                keywords: [application.name]
            )
        }
    }

    private func nestedSections(rows: [CommandPaletteRow], title: String) -> [CommandPaletteSection] {
        let rows = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rows : ranked(rows)
        return rows.isEmpty ? [] : [.init(id: "nested", title: title, rows: rows)]
    }

    private func ranked(_ rows: [CommandPaletteRow]) -> [CommandPaletteRow] {
        var matches: [(row: CommandPaletteRow, rank: Int)] = []
        for row in rows {
            if let rank = row.matchRank(for: query) {
                matches.append((row, rank))
            }
        }
        matches.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.row.title.localizedStandardCompare(rhs.row.title) == .orderedAscending
        }
        return matches.map(\.row)
    }

    private func destinationRow(_ destination: BrowserDestination) -> CommandPaletteRow {
        CommandPaletteRow(
            id: "destination-\(destination.id)",
            title: destination.title,
            detail: destination.detail,
            systemImage: destination.systemImage,
            trailing: destination.kind.rawValue,
            keywords: [destination.kind.rawValue],
            payload: .destination(destination)
        )
    }

    private func fileRow(_ location: CommandPaletteFileLocation) -> CommandPaletteRow {
        CommandPaletteRow(
            id: "file-\(location.id)",
            title: location.item.name,
            detail: "\(location.locationTitle)  ·  \(location.physicalPath)",
            systemImage: location.item.type.commandPaletteSystemImage,
            trailing: location.locationKind,
            keywords: [location.locationTitle, location.locationKind, location.physicalPath],
            payload: .file(location)
        )
    }

    private func command(
        id: String,
        title: String,
        detail: String? = nil,
        icon: String,
        trailing: String? = nil,
        action: CommandPaletteAction,
        destructive: Bool = false,
        keywords: [String] = []
    ) -> CommandPaletteRow {
        CommandPaletteRow(
            id: "command-\(id)",
            title: title,
            detail: detail,
            systemImage: icon,
            trailing: trailing,
            destructive: destructive,
            keywords: keywords,
            payload: .action(action)
        )
    }

    private var flattenedRows: [CommandPaletteRow] { sections.flatMap(\.rows) }

    private func selectFirstRow() {
        DispatchQueue.main.async {
            selectionSource = .automatic
            pointerLocationAtKeyboardSelection = nil
            selectedID = flattenedRows.first?.id
        }
    }

    private func focusQueryField() {
        Task { @MainActor in
            await Task.yield()
            queryFocused = true
        }
    }

    private func moveSelection(by offset: Int) {
        let rows = flattenedRows
        guard !rows.isEmpty else { return }
        let current = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        selectionSource = .keyboard
        pointerLocationAtKeyboardSelection = NSEvent.mouseLocation
        selectedID = rows[min(max(current + offset, 0), rows.count - 1)].id
    }

    private func executeSelection() {
        guard let selectedID,
              let row = flattenedRows.first(where: { $0.id == selectedID })
        else { return }
        execute(row)
    }

    private func execute(_ row: CommandPaletteRow) {
        switch row.payload {
        case .destination(let destination):
            model.openCommandPaletteDestination(destination)
        case .file(let location):
            model.openCommandPaletteFile(location)
        case .action(let action):
            execute(action)
        }
    }

    private func execute(_ action: CommandPaletteAction) {
        switch action {
        case .manageTags: page = .manageTags
        case .manageCollections: page = .manageCollections
        case .selectionTags: page = .selectionTags
        case .selectionCollections: page = .selectionCollections
        case .openWith: page = .openWith
        case .compare: dismissThen { model.startImageComparison() }
        case .jumpTo: dismissThen { model.presentQuickGoto() }
        case .addRootFolder: dismissThen { model.addRootFolder() }
        case .paste: dismissThen { model.pasteFiles() }
        case .clearClipboard: dismissThen { model.confirmsClearingClipboard = true }
        case .shortcuts: model.presentShortcutsHelp()
        case .openSelection: dismissThen { model.openCommandPaletteSelection() }
        case .getInfo:
            guard let item = model.commandPaletteSelectionItems.first else { return }
            dismiss()
            model.registerInfoItem(item)
            openWindow(id: MediaInfoView.windowID, value: item.id)
        case .editMetaTags: dismissThen { model.presentAudioTagsEditor() }
        case .toggleFavorite: dismissThen { model.toggleFavorite() }
        case .setTag(let tag, let enabled): dismissThen { model.setTag(tag, enabled: enabled) }
        case .addToCollection(let collection): dismissThen { model.addToCollection(collection) }
        case .removeFromCollection: dismissThen { model.removeSelectedFromCollection() }
        case .duplicate: dismissThen { model.duplicateCommandPaletteSelection() }
        case .rename: model.presentRenameForCommandPaletteSelection()
        case .copy: dismissThen { model.copyCommandPaletteSelection() }
        case .copyPath: dismissThen { model.copyCommandPaletteSelectionPath() }
        case .reveal: dismissThen { model.revealCommandPaletteSelection() }
        case .trash: dismissThen { model.trashCommandPaletteSelection() }
        case .newTag(let applies): dismissThen { model.organizationEditorRequest = .newTag(applyingSelection: applies) }
        case .editTag(let tag): dismissThen { model.organizationEditorRequest = .editTag(tag) }
        case .deleteTag(let tag): dismissThen { model.deleteTag(tag) }
        case .newCollection(let adds): dismissThen { model.organizationEditorRequest = .newCollection(addingSelection: adds) }
        case .editCollection(let collection): dismissThen { model.organizationEditorRequest = .editCollection(collection) }
        case .deleteCollection(let collection): dismissThen { model.deleteCollection(collection) }
        case .openWithApplication(let application):
            guard let item = model.commandPaletteSelectionItems.first else { return }
            dismissThen { model.openWith(application.url, clicked: item) }
        }
    }

    private func dismissThen(_ action: @escaping @MainActor () -> Void) {
        dismiss()
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }

    private func navigateBackOrDismiss() {
        if page == .root { dismiss() } else { page = .root }
    }

    private func dismiss() { model.dismissCommandPalette() }
}

private extension MediaType {
    var commandPaletteSystemImage: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        }
    }
}

/// Hosts the palette above the AppKit frame view so the scrim covers the unified
/// titlebar and toolbar, matching the Linear-style reference.
struct CommandPaletteWindowPresenter: NSViewRepresentable {
    let model: BrowserModel
    let isPresented: Bool

    func makeNSView(context: Context) -> CommandPaletteOverlayAnchor {
        CommandPaletteOverlayAnchor(model: model, isPresented: isPresented)
    }

    func updateNSView(_ nsView: CommandPaletteOverlayAnchor, context: Context) {
        nsView.update(model: model, isPresented: isPresented)
    }

    static func dismantleNSView(_ nsView: CommandPaletteOverlayAnchor, coordinator: ()) {
        nsView.removeOverlay()
    }
}

final class CommandPaletteOverlayAnchor: NSView {
    private var model: BrowserModel
    private var isPresented: Bool
    private weak var attachedFrameView: NSView?
    private var hostingView: NSHostingView<AnyView>?

    init(model: BrowserModel, isPresented: Bool) {
        self.model = model
        self.isPresented = isPresented
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeOverlay()
    }

    func update(model: BrowserModel, isPresented: Bool) {
        self.model = model
        self.isPresented = isPresented
        synchronizeOverlay()
    }

    func removeOverlay() {
        let window = hostingView?.window
        let restoreBrowserFocus = !isPresented
        hostingView?.removeFromSuperview()
        hostingView = nil
        attachedFrameView = nil
        // Keep the sidebar outline from inheriting first responder when the
        // palette's text field disappears, so the media browser can reclaim it.
        if restoreBrowserFocus {
            window?.makeFirstResponder(window?.contentView)
        }
    }

    private func synchronizeOverlay() {
        guard isPresented, let frameView = window?.contentView?.superview else {
            removeOverlay()
            return
        }
        if attachedFrameView !== frameView { removeOverlay() }

        let rootView = AnyView(CommandPaletteView().environment(model))
        if let hostingView {
            hostingView.rootView = rootView
            hostingView.frame = frameView.bounds
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.frame = frameView.bounds
            hostingView.autoresizingMask = [.width, .height]
            frameView.addSubview(hostingView, positioned: .above, relativeTo: nil)
            self.hostingView = hostingView
            attachedFrameView = frameView
        }
    }
}

#Preview {
    CommandPaletteView()
        .environment(BrowserModel())
        .frame(width: 980, height: 720)
}

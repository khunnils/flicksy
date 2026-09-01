//
//  QuickGotoView.swift
//  Flicksy
//

import SwiftUI

/// One searchable destination in the Command-G picker. Destinations use the
/// same `BrowserSource` values as the sidebar, so choosing one follows the exact
/// same loading and selection path as clicking its row.
struct QuickGotoDestination: Identifiable, Hashable {
    enum Kind: String {
        case library = "Library"
        case collection = "Collection"
        case tag = "Tag"
        case folder = "Folder"
    }

    let id: String
    let title: String
    let detail: String?
    let systemImage: String
    let kind: Kind
    let source: BrowserSource

    fileprivate func matchRank(for query: String) -> Int? {
        let query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !query.isEmpty else { return 3 }

        let title = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let detail = detail?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ?? ""
        let kind = kind.rawValue.lowercased()

        if title == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        if title.contains(query) { return 2 }
        if detail.contains(query) || kind.contains(query) { return 3 }
        return nil
    }
}

extension BrowserModel {
    var quickGotoDestinations: [QuickGotoDestination] {
        var destinations = [
            QuickGotoDestination(
                id: "library-favorites",
                title: "Favorites",
                detail: "Library",
                systemImage: "star.fill",
                kind: .library,
                source: .favorites
            ),
            QuickGotoDestination(
                id: "library-clipboard",
                title: "Clipboard",
                detail: "Library",
                systemImage: "clipboard",
                kind: .library,
                source: .clipboard
            )
        ]

        destinations += StandardBrowserFolder.allCases.map { folder in
            QuickGotoDestination(
                id: "standard-\(folder.rawValue)",
                title: folder.title,
                detail: "Library",
                systemImage: folder.systemImage,
                kind: .library,
                source: .standardFolder(folder)
            )
        }

        destinations += collections.map { collection in
            QuickGotoDestination(
                id: "collection-\(collection.id)",
                title: collection.name,
                detail: "Collection",
                systemImage: "rectangle.stack.badge.play",
                kind: .collection,
                source: .collection(collection.id)
            )
        }

        destinations += tags.map { tag in
            QuickGotoDestination(
                id: "tag-\(tag.id)",
                title: tag.name,
                detail: "Tag",
                systemImage: "tag",
                kind: .tag,
                source: .tag(tag.id)
            )
        }

        for root in rootTrees {
            appendQuickGotoFolders(root, to: &destinations)
        }
        return destinations
    }

    private func appendQuickGotoFolders(
        _ folder: MediaFolder,
        to destinations: inout [QuickGotoDestination]
    ) {
        let parentPath = folder.url.deletingLastPathComponent().path(percentEncoded: false)
        destinations.append(QuickGotoDestination(
            id: "folder-\(folder.id)",
            title: folder.name,
            detail: parentPath,
            systemImage: folder.isRoot ? "folder.badge.gearshape" : "folder",
            kind: .folder,
            source: .folder(folder.id)
        ))
        for child in folder.children {
            appendQuickGotoFolders(child, to: &destinations)
        }
    }
}

struct QuickGotoView: View {
    @Environment(BrowserModel.self) private var model
    @FocusState private var queryFocused: Bool
    @State private var query = ""
    @State private var selectedID: QuickGotoDestination.ID?

    private var filteredDestinations: [QuickGotoDestination] {
        model.quickGotoDestinations.enumerated()
            .compactMap { index, destination -> (QuickGotoDestination, Int, Int)? in
                destination.matchRank(for: query).map { (destination, $0, index) }
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if query.isEmpty { return lhs.2 < rhs.2 }
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(.secondary)
                    TextField("Go to a library or folder", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($queryFocused)
                        .onSubmit(openSelection)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                Divider()

                if filteredDestinations.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(height: 150)
                } else {
                    results
                }
            }
            .frame(width: 520)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08))
            }
            .environment(\.colorScheme, .light)
            .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
            .padding(.top, 72)
        }
        .onAppear {
            selectedID = filteredDestinations.first?.id
            queryFocused = true
            model.isQuickGotoFieldFocused = true
        }
        .onDisappear {
            model.isQuickGotoFieldFocused = false
        }
        .onChange(of: query) {
            selectedID = filteredDestinations.first?.id
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredDestinations) { destination in
                        resultRow(destination)
                            .id(destination.id)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func resultRow(_ destination: QuickGotoDestination) -> some View {
        Button {
            open(destination)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: destination.systemImage)
                    .foregroundStyle(destination.id == selectedID ? Color.white : Color.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(destination.title)
                        .foregroundStyle(destination.id == selectedID ? Color.white : Color.primary)
                        .lineLimit(1)
                    if let detail = destination.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(destination.id == selectedID ? Color.white.opacity(0.78) : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Text(destination.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(destination.id == selectedID ? Color.white.opacity(0.78) : Color.secondary.opacity(0.65))
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .contentShape(Rectangle())
            .background(
                destination.id == selectedID ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedID = destination.id }
        }
    }

    private func moveSelection(by offset: Int) {
        let destinations = filteredDestinations
        guard !destinations.isEmpty else { return }
        let current = selectedID.flatMap { id in destinations.firstIndex { $0.id == id } } ?? 0
        let next = min(max(current + offset, 0), destinations.count - 1)
        selectedID = destinations[next].id
    }

    private func openSelection() {
        guard let selectedID,
              let destination = filteredDestinations.first(where: { $0.id == selectedID })
        else { return }
        open(destination)
    }

    private func open(_ destination: QuickGotoDestination) {
        model.go(to: destination.source)
    }

    private func dismiss() {
        model.isQuickGotoPresented = false
        model.isQuickGotoFieldFocused = false
    }
}

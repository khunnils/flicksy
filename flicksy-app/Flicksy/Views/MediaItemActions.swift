//
//  MediaItemActions.swift
//  MediaBrowser
//

import AppKit
import SwiftUI

/// Context menu and file-URL drag for a media item (spec sections 25 and 26).
struct MediaItemInteractionsModifier: ViewModifier {
    let item: MediaItem
    var model: BrowserModel
    var draggable: Bool

    @State private var hostView: NSView?
    @State private var isDragging = false
    @State private var isRenaming = false
    @State private var proposedName = ""

    func body(content: Content) -> some View {
        content
            .contextMenu { menuItems }
            .background(HostViewCapture { hostView = $0 })
            .simultaneousGesture(dragGesture)
            .alert("Rename", isPresented: $isRenaming) {
                TextField("Filename", text: $proposedName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    model.rename(item, to: proposedName)
                }
                .disabled(proposedName.isEmpty)
            } message: {
                Text("Enter a new name for \(item.name).")
            }
    }

    @ViewBuilder
    private var menuItems: some View {
        if model.viewerItemID == nil {
            Button {
                model.openFromContextMenu(item)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
        }

        Menu {
            let applications = openWithApplications
            if applications.isEmpty {
                Text("No Applications Found")
            } else {
                ForEach(applications) { application in
                    Button {
                        model.openWith(application.url, clicked: item)
                    } label: {
                        Label {
                            Text(application.name)
                        } icon: {
                            Image(nsImage: application.icon)
                        }
                    }
                }
            }
        } label: {
            Label("Open With", systemImage: "macwindow.on.rectangle")
        }

        Divider()

        if item.libraryID != nil {
            let isFavorite = model.selectionIsAllFavorite(clicked: item)
            Button {
                model.toggleFavorite(clicked: item)
            } label: {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }

            if !model.tags.isEmpty {
                Menu("Tags") {
                    ForEach(model.tags) { tag in
                        let applied = model.selectionHasTag(tag, clicked: item)
                        Button {
                            model.setTag(tag, enabled: !applied, clicked: item)
                        } label: {
                            if applied {
                                Label(tag.name, systemImage: "checkmark")
                            } else {
                                Text(tag.name)
                            }
                        }
                    }
                }
            }

            Menu("Add to Collection") {
                if model.collections.isEmpty {
                    Text("No Collections")
                } else {
                    ForEach(model.collections) { collection in
                        Button(collection.name) { model.addToCollection(collection, clicked: item) }
                    }
                }
            }

            if model.isCollectionSelected {
                Button("Remove from Collection", role: .destructive) {
                    _ = model.itemsForAction(clicked: item)
                    model.removeSelectedFromCollection()
                }
            }

            Divider()
        }

        Button {
            model.duplicate(clicked: item)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .disabled(model.isClipboardSelected)
        Button {
            proposedName = item.name
            isRenaming = true
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        .disabled(model.isClipboardSelected)

        Divider()

        Button {
            model.copySelectedFiles(clicked: item)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Button {
            model.pasteFiles()
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(!model.canPasteFiles)

        Divider()

        Button {
            model.revealInFinder(clicked: item)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Button {
            model.copyPath(clicked: item)
        } label: {
            Label("Copy Path", systemImage: "link")
        }

        if item.libraryID != nil {
            Divider()
            Button("Move Original to Trash", role: .destructive) {
                model.moveSelectedFilesToTrashExplicitly(clicked: item)
            }
        }
    }

    private var openWithApplications: [OpenWithApplication] {
        NSWorkspace.shared.urlsForApplications(toOpen: item.url)
            .map { url in
                OpenWithApplication(
                    url: url,
                    name: FileManager.default.displayName(atPath: url.path),
                    icon: NSWorkspace.shared.icon(forFile: url.path)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { _ in
                startDragIfNeeded()
            }
            .onEnded { _ in
                // AppKit owns the session from here; this only covers a drag that
                // never left the view (the session source resets `isDragging`).
            }
    }

    private func startDragIfNeeded() {
        guard draggable, !isDragging else { return }
        guard let hostView else { return }
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDragged || event.type == .leftMouseDown
        else { return }

        let urls = model.prepareDrag(from: item)
        guard !urls.isEmpty else { return }

        isDragging = true
        FileDragSource.shared.onEnd = {
            isDragging = false
        }

        let items: [NSDraggingItem] = urls.map { url in
            let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 64, height: 64)
            let origin = hostView.convert(event.locationInWindow, from: nil)
            dragItem.setDraggingFrame(
                NSRect(x: origin.x - 32, y: origin.y - 32, width: 64, height: 64),
                contents: icon
            )
            return dragItem
        }
        hostView.beginDraggingSession(with: items, event: event, source: FileDragSource.shared)
    }
}

private struct OpenWithApplication: Identifiable {
    var id: String { url.path }

    let url: URL
    let name: String
    let icon: NSImage
}

extension View {
    /// Adds the standard media context menu and, when `draggable`, a native
    /// file-URL drag so clips can be dropped into Finder or an editor.
    func mediaItemInteractions(_ item: MediaItem, model: BrowserModel, draggable: Bool = true) -> some View {
        modifier(MediaItemInteractionsModifier(item: item, model: model, draggable: draggable))
    }
}

// MARK: - AppKit drag bridge

/// Invisible host used only so we can call `beginDraggingSession` with one
/// pasteboard item per file — the way Finder, Final Cut, and CapCut expect
/// multiple files (spec section 26).
private struct HostViewCapture: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> PassThroughView {
        let view = PassThroughView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: PassThroughView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView) }
    }
}

/// Forwards hits so selection, double-click, and hover still reach SwiftUI.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shared drag source for file-URL sessions. Copy-only: the app never moves
/// or deletes files as a result of a drop.
final class FileDragSource: NSObject, NSDraggingSource {
    static let shared = FileDragSource()

    var onEnd: (() -> Void)?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd?()
        onEnd = nil
    }
}

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

    func body(content: Content) -> some View {
        content
            .contextMenu { menuItems }
            .background(HostViewCapture { hostView = $0 })
            .simultaneousGesture(dragGesture)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open") {
            model.openFromContextMenu(item)
        }
        Divider()
        Button("Reveal in Finder") {
            model.revealInFinder(clicked: item)
        }
        Button("Copy Path") {
            model.copyPath(clicked: item)
        }
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

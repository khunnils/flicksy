//
//  MainView.swift
//  MediaBrowser
//

import AppKit
import SwiftUI

/// Accumulates precise (trackpad) scroll deltas so Command-scroll zoom steps at a
/// comfortable rate rather than firing on every fractional event. A reference type
/// so the long-lived event monitor can mutate it.
private final class ZoomScrollAccumulator {
    var value: CGFloat = 0
}

/// Top-level two-pane layout (spec section 3).
struct MainView: View {
    @Environment(BrowserModel.self) private var model

    @State private var scrollMonitor: Any?
    @State private var zoomAccumulator = ZoomScrollAccumulator()

    /// Points of accumulated scroll needed to move one zoom step.
    private let zoomScrollThreshold: CGFloat = 12

    var body: some View {
        NavigationSplitView {
            FolderSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            MediaBrowserView()
                .navigationTitle(selectedSourceTitle)
                .toolbar {
                    if model.viewerItem == nil {
                        ToolbarItem(placement: .principal) {
                            LibraryTabPicker()
                        }
                        ToolbarItem {
                            SortControl()
                        }
                        ToolbarItem {
                            OrganizationControl()
                        }
                        ToolbarItem(placement: .primaryAction) {
                            if model.libraryTab == .visual {
                                GridZoomControl()
                            }
                        }
                    } else {
                        ToolbarItem(placement: .primaryAction) {
                            ImageViewerToolbar()
                        }
                    }
                }
                .modifier(PreviewToolbarStyle(isPreviewing: model.viewerItem != nil))
        }
        .overlay {
            // Overlaying the split view (rather than using a sheet) lets the
            // viewer cover the sidebar and fill the window, per spec section 16.
            if let item = model.viewerItem {
                MediaViewer(item: item)
                    .transition(.opacity)
            }
        }
        .overlay {
            if model.isQuickGotoPresented {
                QuickGotoView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .background {
            KeyboardShortcutsWindowPresenter(
                model: model,
                isPresented: model.isShortcutsHelpPresented
            )
            .frame(width: 0, height: 0)
        }
        .animation(.easeInOut(duration: 0.15), value: model.viewerItemID)
        .animation(.easeOut(duration: 0.12), value: model.isQuickGotoPresented)
        .task {
            model.restore()
        }
        .onAppear {
            installScrollMonitor()
        }
        .onDisappear {
            removeScrollMonitor()
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
        .alert(
            "Organization Problem",
            isPresented: Binding(
                get: { model.organizationError != nil },
                set: { if !$0 { model.organizationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.organizationError = nil }
        } message: {
            Text(model.organizationError ?? "")
        }
        .sheet(item: Binding(
            get: { model.editAudioTagsRequest },
            set: { model.editAudioTagsRequest = $0 }
        )) { request in
            AudioTagsEditor(items: request.items)
                .environment(model)
        }
    }

    private var selectedSourceTitle: String {
        switch model.selectedSource {
        case .favorites:
            "Favorites"
        case .tag(let id):
            model.tags.first(where: { $0.id == id })?.name ?? "Tag"
        case .collection(let id):
            model.collections.first(where: { $0.id == id })?.name ?? "Collection"
        case .clipboard:
            "Clipboard"
        case .standardFolder(let folder):
            folder.title
        case .folder(let id):
            URL(fileURLWithPath: id).lastPathComponent
        case nil:
            "Flicksy"
        }
    }

    // MARK: - Command-scroll zoom

    /// Zoom the active visual surface with Command + scroll wheel: the image when
    /// viewing a still, otherwise the thumbnail grid.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.contains(.command),
                  model.isViewingImage || (model.viewerItemID == nil && model.libraryTab == .visual)
            else { return event }

            handleZoomScroll(event)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
    }

    private func handleZoomScroll(_ event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }

        if event.hasPreciseScrollingDeltas {
            // Trackpads emit many small deltas; accumulate to one step at a time.
            zoomAccumulator.value += delta
            while zoomAccumulator.value >= zoomScrollThreshold {
                zoomAccumulator.value -= zoomScrollThreshold
                zoomIn()
            }
            while zoomAccumulator.value <= -zoomScrollThreshold {
                zoomAccumulator.value += zoomScrollThreshold
                zoomOut()
            }
        } else {
            // A mouse wheel notch is one discrete step.
            if delta > 0 { zoomIn() } else { zoomOut() }
        }
    }

    private func zoomIn() {
        if model.isViewingImage { model.zoomViewerImageIn() } else { model.zoomIn() }
    }

    private func zoomOut() {
        if model.isViewingImage { model.zoomViewerImageOut() } else { model.zoomOut() }
    }
}

/// Opaque white titlebar while the media viewer is open, so the unified toolbar
/// does not pick up a grey material over the preview.
private struct PreviewToolbarStyle: ViewModifier {
    let isPreviewing: Bool

    func body(content: Content) -> some View {
        if isPreviewing {
            content
                .toolbarBackground(Color.white, for: .windowToolbar)
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
                .toolbarColorScheme(.light, for: .windowToolbar)
        } else {
            content
        }
    }
}

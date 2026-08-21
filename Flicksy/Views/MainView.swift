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
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            MediaBrowserView()
                .navigationTitle("Media Browser")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        GridZoomControl()
                    }
                }
        }
        .overlay {
            // Overlaying the split view (rather than using a sheet) lets the
            // viewer cover the sidebar and fill the window, per spec section 16.
            if let item = model.viewerItem {
                MediaViewer(item: item)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.viewerItemID)
        .task {
            model.restore()
        }
        .onAppear { installScrollMonitor() }
        .onDisappear { removeScrollMonitor() }
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

    // MARK: - Command-scroll zoom

    /// Zoom the grid with Command + scroll wheel. Ignored while the viewer is open;
    /// events without the Command modifier pass through untouched.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard model.viewerItemID == nil,
                  event.modifierFlags.contains(.command)
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
                model.zoomIn()
            }
            while zoomAccumulator.value <= -zoomScrollThreshold {
                zoomAccumulator.value += zoomScrollThreshold
                model.zoomOut()
            }
        } else {
            // A mouse wheel notch is one discrete step.
            if delta > 0 { model.zoomIn() } else { model.zoomOut() }
        }
    }
}

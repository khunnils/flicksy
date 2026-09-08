import AppKit
import SwiftUI

/// One presenter per browser model; never chooses a window using global focus.
@MainActor
final class MediaSharingPresenter {
    weak var anchorView: NSView?
    private var picker: NSSharingServicePicker?
    private var requestID = UUID()

    func present(urls: [URL], from sourceView: NSView? = nil) {
        cancel()
        guard !urls.isEmpty, let window = anchorView?.window else { return }
        let requestID = requestID

        // Leave menu tracking and let the command-palette overlay disappear.
        DispatchQueue.main.async { [weak self, weak window, weak sourceView] in
            guard let self, self.requestID == requestID,
                  let window, window.isVisible,
                  self.anchorView?.window === window,
                  let contentView = window.contentView else { return }

            let view: NSView
            let rect: NSRect
            if let sourceView, sourceView.window === window {
                view = sourceView
                rect = sourceView.bounds
            } else {
                view = contentView
                let bounds = contentView.bounds
                let y = contentView.isFlipped ? bounds.minY + 12 : bounds.maxY - 12
                rect = NSRect(x: bounds.midX, y: y, width: 1, height: 1)
            }
            let picker = NSSharingServicePicker(items: urls)
            self.picker = picker
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
    }

    func cancel() {
        requestID = UUID()
        picker?.close()
        picker = nil
    }
}

struct MediaSharingWindowAnchor: NSViewRepresentable {
    let presenter: MediaSharingPresenter

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.presenter = presenter
        presenter.anchorView = view
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {}

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.presenter?.cancel()
        nsView.presenter?.anchorView = nil
    }

    final class AnchorView: NSView {
        weak var presenter: MediaSharingPresenter?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { presenter?.cancel() }
        }
    }
}

//
//  KeyboardShortcutsView.swift
//  Flicksy
//

import AppKit
import SwiftUI

/// One listed shortcut in the Command-/ helper.
struct KeyboardShortcutEntry: Identifiable, Hashable {
    let id: String
    let title: String
    /// Right-aligned shortcut text, e.g. `"⌘G"` or `"⇧← → ↑ ↓"`.
    let keys: String
}

struct KeyboardShortcutSection: Identifiable, Hashable {
    let id: String
    let title: String
    let entries: [KeyboardShortcutEntry]
}

enum KeyboardShortcutsCatalog {
    static let sections: [KeyboardShortcutSection] = [
        KeyboardShortcutSection(
            id: "general",
            title: "General",
            entries: [
                .init(id: "command-palette", title: "Command palette", keys: "⌘K"),
                .init(id: "quick-goto", title: "Quick Goto", keys: "⌘G"),
                .init(id: "find-media", title: "Find Media", keys: "⌘F"),
                .init(id: "organize", title: "Organize", keys: "⌘T"),
                .init(id: "get-info", title: "Get Info", keys: "⌘I"),
                .init(id: "shortcuts", title: "View keyboard shortcuts", keys: "⌘/"),
            ]
        ),
        KeyboardShortcutSection(
            id: "library",
            title: "Library",
            entries: [
                .init(id: "tab-all", title: "All", keys: "⌘1"),
                .init(id: "tab-visual", title: "Images & Video", keys: "⌘2"),
                .init(id: "tab-audio", title: "Audio", keys: "⌘3"),
                .init(id: "zoom-in", title: "Zoom in", keys: "+"),
                .init(id: "zoom-out", title: "Zoom out", keys: "−"),
            ]
        ),
        KeyboardShortcutSection(
            id: "selection",
            title: "Selection",
            entries: [
                .init(id: "select-all", title: "Select all", keys: "⌘A"),
                .init(id: "copy", title: "Copy", keys: "⌘C"),
                .init(id: "paste", title: "Paste", keys: "⌘V"),
                .init(id: "copy-path", title: "Copy path", keys: "⌘⌥C"),
                .init(id: "reveal", title: "Reveal in Finder", keys: "⌘⌥R"),
                .init(id: "trash", title: "Move to Trash", keys: "⌘⌫"),
            ]
        ),
        KeyboardShortcutSection(
            id: "browser",
            title: "Browser",
            entries: [
                .init(id: "move-focus", title: "Move focus", keys: "← → ↑ ↓"),
                .init(id: "extend-selection", title: "Extend selection", keys: "⇧← → ↑ ↓"),
                .init(id: "preview", title: "Open preview", keys: "Space"),
                .init(id: "play-return", title: "Play / Pause", keys: "Return"),
                .init(id: "delete", title: "Move to Trash", keys: "⌫"),
            ]
        ),
        KeyboardShortcutSection(
            id: "viewer",
            title: "Viewer",
            entries: [
                .init(id: "prev-next", title: "Previous / Next", keys: "← →"),
                .init(id: "viewer-play", title: "Play / Pause", keys: "Space"),
                .init(id: "fullscreen", title: "Toggle full screen", keys: "F"),
                .init(id: "close-viewer", title: "Close", keys: "Esc"),
            ]
        ),
        KeyboardShortcutSection(
            id: "audio",
            title: "Audio",
            entries: [
                .init(id: "jump-start", title: "Jump to start", keys: "⌘←"),
                .init(id: "rewind", title: "Rewind 5 seconds", keys: "←"),
                .init(id: "forward", title: "Forward 5 seconds", keys: "→"),
                .init(id: "jump-end", title: "Jump to end", keys: "⌘→"),
            ]
        ),
    ]
}

struct KeyboardShortcutsView: View {
    @Environment(BrowserModel.self) private var model

    private let panelShape = RoundedRectangle(cornerRadius: 13, style: .continuous)

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                header

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(KeyboardShortcutsCatalog.sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }
            .frame(width: 404)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor), in: panelShape)
            .clipShape(panelShape)
            .overlay {
                panelShape.strokeBorder(.primary.opacity(0.09), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 24, x: -4, y: 8)
            .padding(12)
            // Escape dismisses via the standard cancel action — no focus ring.
            .background {
                Button("Close", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.leading, 22)
        .padding(.trailing, 16)
        .padding(.top, 17)
        .padding(.bottom, 13)
    }

    private func sectionView(_ section: KeyboardShortcutSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.bottom, 5)

            ForEach(section.entries) { entry in
                HStack(spacing: 14) {
                    Text(entry.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ShortcutKeycaps(keys: entry.keys)
                }
                .frame(minHeight: 30)
            }
        }
    }

    private func dismiss() {
        model.isShortcutsHelpPresented = false
    }
}

private struct ShortcutKeycaps: View {
    let keys: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(token)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, token.count > 1 ? 6 : 4)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.primary.opacity(0.11), lineWidth: 1)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys)
    }

    private var tokens: [String] {
        let standaloneGlyphs = Set("⌘⌥⇧⌃←→↑↓⌫")
        var result: [String] = []

        for component in keys.split(whereSeparator: \Character.isWhitespace) {
            var word = ""
            for character in component {
                if standaloneGlyphs.contains(character) {
                    if !word.isEmpty {
                        result.append(word)
                        word = ""
                    }
                    result.append(String(character))
                } else {
                    word.append(character)
                }
            }
            if !word.isEmpty { result.append(word) }
        }
        return result
    }
}

/// Attaches the shortcuts overlay to the window frame rather than the SwiftUI
/// content view. The frame includes the unified titlebar and toolbar, allowing
/// one scrim to dim the complete app chrome just like the Linear reference.
struct KeyboardShortcutsWindowPresenter: NSViewRepresentable {
    let model: BrowserModel
    let isPresented: Bool

    func makeNSView(context: Context) -> KeyboardShortcutsOverlayAnchor {
        KeyboardShortcutsOverlayAnchor(model: model, isPresented: isPresented)
    }

    func updateNSView(_ nsView: KeyboardShortcutsOverlayAnchor, context: Context) {
        nsView.update(model: model, isPresented: isPresented)
    }

    static func dismantleNSView(_ nsView: KeyboardShortcutsOverlayAnchor, coordinator: ()) {
        nsView.removeOverlay()
    }
}

final class KeyboardShortcutsOverlayAnchor: NSView {
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
        hostingView?.removeFromSuperview()
        hostingView = nil
        attachedFrameView = nil
    }

    private func synchronizeOverlay() {
        guard isPresented,
              let frameView = window?.contentView?.superview
        else {
            removeOverlay()
            return
        }

        if attachedFrameView !== frameView {
            removeOverlay()
        }

        let rootView = AnyView(KeyboardShortcutsView().environment(model))
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
    KeyboardShortcutsView()
        .environment(BrowserModel())
        .frame(width: 700, height: 700)
}

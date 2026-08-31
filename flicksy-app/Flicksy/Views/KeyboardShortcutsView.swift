//
//  KeyboardShortcutsView.swift
//  Flicksy
//

import SwiftUI

/// One listed shortcut in the Command-/ helper. Keys are rendered as Linear-style
/// glyph strings (⌘, ⌥, ←) rather than bordered keycaps.
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

    private let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(KeyboardShortcutsCatalog.sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 20)
                }
            }
            .frame(width: 380)
            .frame(maxHeight: 520)
            .background(.background, in: cardShape)
            .clipShape(cardShape)
            .overlay {
                cardShape.strokeBorder(.primary.opacity(0.08))
            }
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            // Escape dismisses via the standard cancel action — no focus ring.
            .background {
                Button("Close", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.system(.body, design: .default).weight(.semibold))
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func sectionView(_ section: KeyboardShortcutSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(section.entries) { entry in
                HStack(spacing: 16) {
                    Text(entry.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(entry.keys)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 5)
            }
        }
    }

    private func dismiss() {
        model.isShortcutsHelpPresented = false
    }
}

#Preview {
    KeyboardShortcutsView()
        .environment(BrowserModel())
        .frame(width: 700, height: 700)
}

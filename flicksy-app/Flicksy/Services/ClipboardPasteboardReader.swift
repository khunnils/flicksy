//
//  ClipboardPasteboardReader.swift
//  MediaBrowser
//

import AppKit
import UniformTypeIdentifiers

/// Converts one stable pasteboard snapshot into image candidates. Reading stays
/// on the main actor because pasteboard owners may vend representations lazily.
@MainActor
enum ClipboardPasteboardReader {
    static func candidates(from pasteboard: NSPasteboard) -> [ClipboardImageCandidate] {
        var candidates: [ClipboardImageCandidate] = []

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] {
            candidates.append(contentsOf: urls.map {
                .file($0, originalName: $0.lastPathComponent)
            })
        }

        // A file URL may also advertise a rendered TIFF preview. Prefer the file
        // representation so one pasteboard item cannot import twice.
        for item in pasteboard.pasteboardItems ?? [] where !item.types.contains(.fileURL) {
            if let data = item.data(forType: .png) {
                candidates.append(.data(data, preferredExtension: "png", originalName: ""))
            } else if let data = item.data(forType: .tiff) {
                candidates.append(.data(data, preferredExtension: "tiff", originalName: ""))
            }
        }

        // Some editors expose only a custom image representation that NSImage can
        // negotiate. Use this fallback only when no direct representation matched.
        if candidates.isEmpty,
           let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            for image in images {
                if let data = PersistentMediaCache.encodedImage(image) {
                    candidates.append(.data(data, preferredExtension: "png", originalName: ""))
                }
            }
        }

        return candidates
    }
}

//
//  MediaType.swift
//  MediaBrowser
//

import Foundation
import UniformTypeIdentifiers

/// The three broad categories of media the browser understands.
///
/// Classification is driven by `UTType` rather than a hardcoded extension list so
/// that any format the system knows about (and that conforms to the relevant base
/// type) is handled without maintaining our own table.
enum MediaType: Sendable {
    case image
    case video
    case audio

    /// Classify a content type into a media category, or `nil` if it is not media.
    ///
    /// Order matters: some container formats conform to more than one base type.
    /// For example an `.m4a` audio file conforms to both `public.audio` and
    /// `public.audiovisual-content`, so audio must be checked before video to
    /// avoid misclassifying audio-only assets as video.
    nonisolated init?(contentType: UTType) {
        if contentType.conforms(to: .image) {
            self = .image
        } else if contentType.conforms(to: .audio) {
            self = .audio
        } else if contentType.conforms(to: .movie) || contentType.conforms(to: .audiovisualContent) {
            self = .video
        } else {
            return nil
        }
    }
}

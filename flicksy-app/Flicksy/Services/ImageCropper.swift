//
//  ImageCropper.swift
//  Flicksy
//

import AppKit
import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Crops an on-disk image and atomically replaces the original file.
enum ImageCropper {
    enum Transform: Sendable {
        case rotateLeft
        case rotateRight
        case flipHorizontal
        case flipVertical

        fileprivate nonisolated var orientation: CGImagePropertyOrientation {
            switch self {
            case .rotateLeft: .left
            case .rotateRight: .right
            case .flipHorizontal: .upMirrored
            case .flipVertical: .downMirrored
            }
        }
    }

    enum CropError: LocalizedError {
        case unreadable
        case invalidRect
        case transformFailed
        case encodeFailed
        case replaceFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: "This image could not be opened for editing."
            case .invalidRect: "The crop area is too small."
            case .transformFailed: "This image could not be rotated or flipped."
            case .encodeFailed: "The edited image could not be saved in this format."
            case .replaceFailed: "The original file could not be replaced. If this folder was added before write access was enabled, remove and re-add it."
            }
        }
    }

    /// `normalizedRect` is in oriented image space (origin top-left, 0…1).
    nonisolated static func crop(url: URL, normalizedRect: CGRect) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { throw CropError.unreadable }

        guard let oriented = orientedFullImage(from: source) else {
            throw CropError.unreadable
        }

        let pixelRect = pixelCropRect(normalized: normalizedRect, imageSize: oriented.size)
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = oriented.image.cropping(to: pixelRect)
        else { throw CropError.invalidRect }

        let uti = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        try writeReplacing(url: url, image: cropped, preferredType: uti)

        return CGSize(width: cropped.width, height: cropped.height)
    }

    /// Applies a geometric transform to the display-oriented pixels, then
    /// atomically replaces the original file.
    nonisolated static func transform(url: URL, operation: Transform) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let oriented = orientedFullImage(from: source)
        else { throw CropError.unreadable }

        let transformed = CIImage(cgImage: oriented.image).oriented(operation.orientation)
        guard let output = CIContext().createCGImage(transformed, from: transformed.extent)
        else { throw CropError.transformFailed }

        let uti = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        try writeReplacing(url: url, image: output, preferredType: uti)
        return CGSize(width: output.width, height: output.height)
    }

    // MARK: - Decode

    private struct OrientedImage {
        let image: CGImage
        var size: CGSize { CGSize(width: image.width, height: image.height) }
    }

    /// Full-resolution decode with EXIF orientation already applied, matching
    /// how the viewer presents the still.
    nonisolated private static func orientedFullImage(from source: CGImageSource) -> OrientedImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return OrientedImage(image: image)
    }

    nonisolated private static func pixelCropRect(normalized: CGRect, imageSize: CGSize) -> CGRect {
        let clamped = CGRect(
            x: min(max(normalized.origin.x, 0), 1),
            y: min(max(normalized.origin.y, 0), 1),
            width: min(max(normalized.width, 0), 1),
            height: min(max(normalized.height, 0), 1)
        )
        var rect = CGRect(
            x: (clamped.origin.x * imageSize.width).rounded(.down),
            y: (clamped.origin.y * imageSize.height).rounded(.down),
            width: (clamped.width * imageSize.width).rounded(.up),
            height: (clamped.height * imageSize.height).rounded(.up)
        )
        rect = rect.intersection(CGRect(origin: .zero, size: imageSize))
        return rect.integral
    }

    // MARK: - Write

    nonisolated private static func writeReplacing(url: URL, image: CGImage, preferredType: UTType?) throws {
        let type = writableType(preferred: preferredType)
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "flicksy-image-edit-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")

        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw CropError.encodeFailed
        }

        var properties: [CFString: Any] = [:]
        if type.conforms(to: .jpeg) {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            throw CropError.encodeFailed
        }

        do {
            let result = try FileManager.default.replaceItemAt(
                url,
                withItemAt: temporary,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
            if let result, result != url {
                // Rare: replacement produced a different URL; move back.
                try FileManager.default.moveItem(at: result, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw CropError.replaceFailed
        }
    }

    nonisolated private static func writableType(preferred: UTType?) -> UTType {
        if let preferred {
            if preferred.conforms(to: .jpeg) { return .jpeg }
            if preferred.conforms(to: .png) { return .png }
            if preferred.conforms(to: .tiff) { return .tiff }
            if preferred.conforms(to: .heic) { return .heic }
            if preferred.conforms(to: .gif) { return .gif }
            if preferred.conforms(to: .webP) { return .webP }
            if preferred.conforms(to: .image) { return preferred }
        }
        return .jpeg
    }
}

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

/// Full-resolution on-disk image edits that atomically replace the original file.
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
        case invalidSize
        case transformFailed
        case unsupportedFormat
        case resizeFailed
        case encodeFailed
        case replaceFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: "This image could not be opened for editing."
            case .invalidRect: "The crop area is too small."
            case .invalidSize: "Enter a valid image width and height."
            case .transformFailed: "This image could not be rotated or flipped."
            case .unsupportedFormat: "This image format cannot be resized without losing frames."
            case .resizeFailed: "The image could not be resized to those dimensions."
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

    /// Resizes every frame to the exact display-oriented pixel dimensions while
    /// preserving animation and descriptive metadata supported by ImageIO.
    nonisolated static func resize(url: URL, pixelSize: CGSize) throws -> CGSize {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0,
              pixelSize.width <= CGFloat(Int.max), pixelSize.height <= CGFloat(Int.max)
        else { throw CropError.invalidSize }

        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { throw CropError.unreadable }

        let writableIdentifiers = CGImageDestinationCopyTypeIdentifiers() as NSArray
        guard let identifier = CGImageSourceGetType(source) as String?,
              writableIdentifiers.contains(identifier)
        else { throw CropError.unsupportedFormat }

        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "flicksy-image-resize-\(UUID().uuidString).\(UTType(identifier)?.preferredFilenameExtension ?? "img")")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            identifier as CFString,
            count,
            nil
        ) else { throw CropError.unsupportedFormat }

        if let sourceProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] {
            let properties = resizedProperties(sourceProperties, width: width, height: height)
            CGImageDestinationSetProperties(destination, properties as CFDictionary)
        }

        let context = CIContext(options: [.cacheIntermediates: false])
        for index in 0..<count {
            guard let frame = orientedFullImage(from: source, index: index)?.image,
                  let resized = resizedImage(frame, width: width, height: height, context: context)
            else { throw CropError.resizeFailed }

            var properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
            properties = resizedProperties(properties, width: width, height: height)
            if UTType(identifier)?.conforms(to: .jpeg) == true {
                properties[kCGImageDestinationLossyCompressionQuality] = 0.92
            }
            CGImageDestinationAddImage(destination, resized, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { throw CropError.encodeFailed }
        try replaceOriginal(at: url, with: temporary)
        return CGSize(width: width, height: height)
    }

    // MARK: - Decode

    private struct OrientedImage {
        let image: CGImage
        nonisolated var size: CGSize { CGSize(width: image.width, height: image.height) }
    }

    /// Full-resolution decode with EXIF orientation already applied, matching
    /// how the viewer presents the still.
    nonisolated private static func orientedFullImage(from source: CGImageSource) -> OrientedImage? {
        orientedFullImage(from: source, index: 0)
    }

    nonisolated private static func orientedFullImage(
        from source: CGImageSource,
        index: Int
    ) -> OrientedImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        else { return nil }
        return OrientedImage(image: image)
    }

    nonisolated private static func resizedImage(
        _ image: CGImage,
        width: Int,
        height: Int,
        context: CIContext
    ) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard input.extent.width > 0, input.extent.height > 0,
              let filter = CIFilter(name: "CILanczosScaleTransform")
        else { return nil }

        let scaleY = CGFloat(height) / input.extent.height
        let scaleX = CGFloat(width) / input.extent.width
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scaleY, forKey: kCIInputScaleKey)
        filter.setValue(scaleX / scaleY, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { return nil }

        let bounds = CGRect(
            x: output.extent.minX,
            y: output.extent.minY,
            width: CGFloat(width),
            height: CGFloat(height)
        )
        let outputFormat: CIFormat
        if image.bitmapInfo.contains(.floatComponents) {
            outputFormat = .RGBAh
        } else if image.bitsPerComponent > 8 {
            outputFormat = .RGBA16
        } else {
            outputFormat = .RGBA8
        }
        return context.createCGImage(
            output,
            from: bounds,
            format: outputFormat,
            colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        )
    }

    nonisolated private static func resizedProperties(
        _ original: [CFString: Any],
        width: Int,
        height: Int
    ) -> [CFString: Any] {
        var properties = original
        properties[kCGImagePropertyPixelWidth] = width
        properties[kCGImagePropertyPixelHeight] = height
        properties[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue

        updateNestedDictionary(&properties, key: kCGImagePropertyTIFFDictionary) { dictionary in
            dictionary[kCGImagePropertyTIFFOrientation] = CGImagePropertyOrientation.up.rawValue
        }
        updateNestedDictionary(&properties, key: kCGImagePropertyExifDictionary) { dictionary in
            dictionary[kCGImagePropertyExifPixelXDimension] = width
            dictionary[kCGImagePropertyExifPixelYDimension] = height
        }
        updateAnimationCanvas(
            &properties,
            dictionaryKey: kCGImagePropertyGIFDictionary,
            widthKey: kCGImagePropertyGIFCanvasPixelWidth,
            heightKey: kCGImagePropertyGIFCanvasPixelHeight,
            width: width,
            height: height
        )
        updateAnimationCanvas(
            &properties,
            dictionaryKey: kCGImagePropertyPNGDictionary,
            widthKey: kCGImagePropertyAPNGCanvasPixelWidth,
            heightKey: kCGImagePropertyAPNGCanvasPixelHeight,
            width: width,
            height: height
        )
        updateAnimationCanvas(
            &properties,
            dictionaryKey: kCGImagePropertyWebPDictionary,
            widthKey: kCGImagePropertyWebPCanvasPixelWidth,
            heightKey: kCGImagePropertyWebPCanvasPixelHeight,
            width: width,
            height: height
        )
        updateAnimationCanvas(
            &properties,
            dictionaryKey: kCGImagePropertyHEICSDictionary,
            widthKey: kCGImagePropertyHEICSCanvasPixelWidth,
            heightKey: kCGImagePropertyHEICSCanvasPixelHeight,
            width: width,
            height: height
        )
        return properties
    }

    nonisolated private static func updateAnimationCanvas(
        _ properties: inout [CFString: Any],
        dictionaryKey: CFString,
        widthKey: CFString,
        heightKey: CFString,
        width: Int,
        height: Int
    ) {
        updateNestedDictionary(&properties, key: dictionaryKey) { dictionary in
            dictionary[widthKey] = width
            dictionary[heightKey] = height
        }
    }

    nonisolated private static func updateNestedDictionary(
        _ properties: inout [CFString: Any],
        key: CFString,
        update: (inout [CFString: Any]) -> Void
    ) {
        guard var dictionary = properties[key] as? [CFString: Any] else { return }
        update(&dictionary)
        properties[key] = dictionary
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
            try replaceOriginal(at: url, with: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw CropError.replaceFailed
        }
    }

    nonisolated private static func replaceOriginal(at url: URL, with temporary: URL) throws {
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

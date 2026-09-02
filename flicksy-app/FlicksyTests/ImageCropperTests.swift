//
//  ImageCropperTests.swift
//  FlicksyTests
//

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Flicksy

final class ImageCropperTests: XCTestCase {
    private var imageURL: URL!

    override func setUpWithError() throws {
        imageURL = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyTransform-\(UUID().uuidString).png")
        try writeAsymmetricTestImage(to: imageURL)
    }

    override func tearDownWithError() throws {
        if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
    }

    func testRotateRightThenLeftRestoresPixels() throws {
        let original = try decodedPixels(at: imageURL)

        let rotated = try ImageCropper.transform(url: imageURL, operation: .rotateRight)
        XCTAssertEqual(rotated, CGSize(width: 2, height: 3))
        XCTAssertNotEqual(try decodedPixels(at: imageURL).bytes, original.bytes)

        let restored = try ImageCropper.transform(url: imageURL, operation: .rotateLeft)
        XCTAssertEqual(restored, CGSize(width: 3, height: 2))
        XCTAssertEqual(try decodedPixels(at: imageURL), original)
    }

    func testHorizontalAndVerticalFlipsAreReversible() throws {
        let original = try decodedPixels(at: imageURL)

        _ = try ImageCropper.transform(url: imageURL, operation: .flipHorizontal)
        XCTAssertNotEqual(try decodedPixels(at: imageURL), original)
        _ = try ImageCropper.transform(url: imageURL, operation: .flipHorizontal)
        XCTAssertEqual(try decodedPixels(at: imageURL), original)

        _ = try ImageCropper.transform(url: imageURL, operation: .flipVertical)
        XCTAssertNotEqual(try decodedPixels(at: imageURL), original)
        _ = try ImageCropper.transform(url: imageURL, operation: .flipVertical)
        XCTAssertEqual(try decodedPixels(at: imageURL), original)
    }

    func testResizeWritesExactDimensionsAndKeepsPNGFormat() throws {
        let resized = try ImageCropper.resize(
            url: imageURL,
            pixelSize: CGSize(width: 7, height: 5)
        )

        XCTAssertEqual(resized, CGSize(width: 7, height: 5))
        let decoded = try decodedPixels(at: imageURL)
        XCTAssertEqual(decoded.width, 7)
        XCTAssertEqual(decoded.height, 5)
        XCTAssertEqual(try imageSource(at: imageURL).type, UTType.png.identifier)
    }

    func testResizePreservesTransparency() throws {
        let transparentURL = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyTransparent-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: transparentURL) }
        let image = try asymmetricTestImage(bytes: [
            0, 0, 0, 0,         0, 255, 0, 128,     0, 0, 255, 255,
            0, 255, 255, 255,   255, 0, 255, 255,   255, 255, 0, 255,
        ])
        try writeImage(image, to: transparentURL, type: .png)

        _ = try ImageCropper.resize(url: transparentURL, pixelSize: CGSize(width: 9, height: 6))

        let pixels = try decodedPixels(at: transparentURL).bytes
        let alphaValues = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        XCTAssertTrue(alphaValues.contains(where: { $0 < 255 }))
    }

    func testResizeNormalizesOrientationAndUsesDisplayDimensions() throws {
        let orientedURL = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyOriented-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: orientedURL) }
        try writeAsymmetricTestImage(
            to: orientedURL,
            type: .jpeg,
            properties: [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue]
        )
        XCTAssertEqual(ThumbnailService.pixelSize(for: orientedURL), CGSize(width: 2, height: 3))

        _ = try ImageCropper.resize(url: orientedURL, pixelSize: CGSize(width: 4, height: 6))

        let source = try imageSource(at: orientedURL)
        XCTAssertEqual(source.image.width, 4)
        XCTAssertEqual(source.image.height, 6)
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source.source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)
    }

    func testResizePreservesAnimatedGIFFramesTimingAndLoopCount() throws {
        let animatedURL = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyAnimated-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: animatedURL) }
        try writeAnimatedGIF(to: animatedURL)

        _ = try ImageCropper.resize(url: animatedURL, pixelSize: CGSize(width: 9, height: 6))

        let source = try imageSource(at: animatedURL)
        XCTAssertEqual(CGImageSourceGetCount(source.source), 2)
        XCTAssertEqual(source.image.width, 9)
        XCTAssertEqual(source.image.height, 6)
        let container = try XCTUnwrap(
            CGImageSourceCopyProperties(source.source, nil) as? [CFString: Any]
        )
        let gif = try XCTUnwrap(container[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual((gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(frameDelay(at: 0, in: source.source), 0.2, accuracy: 0.01)
        XCTAssertEqual(frameDelay(at: 1, in: source.source), 0.4, accuracy: 0.01)
    }

    func testInvalidResizeLeavesOriginalUntouched() throws {
        let original = try Data(contentsOf: imageURL)

        XCTAssertThrowsError(
            try ImageCropper.resize(url: imageURL, pixelSize: CGSize(width: 0, height: 10))
        )
        XCTAssertEqual(try Data(contentsOf: imageURL), original)
    }

    func testReplacementFailureLeavesOriginalUntouched() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyReadOnly-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "image.png")
        try writeAsymmetricTestImage(to: url)
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertThrowsError(
            try ImageCropper.resize(url: url, pixelSize: CGSize(width: 8, height: 8))
        )
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func writeAsymmetricTestImage(
        to url: URL,
        type: UTType = .png,
        properties: [CFString: Any]? = nil
    ) throws {
        let image = try asymmetricTestImage()
        try writeImage(image, to: url, type: type, properties: properties)
    }

    private func writeImage(
        _ image: CGImage,
        to url: URL,
        type: UTType,
        properties: [CFString: Any]? = nil
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else { return XCTFail("Could not create test destination") }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func asymmetricTestImage(bytes: [UInt8]? = nil) throws -> CGImage {
        let defaultBytes: [UInt8] = [
            255, 0, 0, 255,     0, 255, 0, 255,     0, 0, 255, 255,
            0, 255, 255, 255,   255, 0, 255, 255,   255, 255, 0, 255,
        ]
        guard let provider = CGDataProvider(data: Data(bytes ?? defaultBytes) as CFData),
              let image = CGImage(
                width: 3,
                height: 2,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 12,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { throw TestError.decodeFailed }
        return image
    }

    private func writeAnimatedGIF(to url: URL) throws {
        let first = try asymmetricTestImage()
        let second = try asymmetricTestImage(bytes: [
            0, 0, 0, 255,       255, 255, 255, 255,  255, 128, 0, 255,
            128, 0, 255, 255,   0, 128, 255, 255,    128, 255, 0, 255,
        ])
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            2,
            nil
        ) else { return XCTFail("Could not create animated GIF") }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3],
        ] as CFDictionary)
        CGImageDestinationAddImage(destination, first, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2],
        ] as CFDictionary)
        CGImageDestinationAddImage(destination, second, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func frameDelay(at index: Int, in source: CGImageSource) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        return (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
    }

    private func imageSource(at url: URL) throws -> DecodedSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let type = CGImageSourceGetType(source) as String?
        else { throw TestError.decodeFailed }
        return DecodedSource(source: source, image: image, type: type)
    }

    private func decodedPixels(at url: URL) throws -> PixelImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw TestError.decodeFailed }

        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestError.decodeFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return PixelImage(width: image.width, height: image.height, bytes: bytes)
    }

    private struct PixelImage: Equatable {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private struct DecodedSource {
        let source: CGImageSource
        let image: CGImage
        let type: String
    }

    private enum TestError: Error {
        case decodeFailed
    }
}

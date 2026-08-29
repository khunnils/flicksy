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

    private func writeAsymmetricTestImage(to url: URL) throws {
        let bytes: [UInt8] = [
            255, 0, 0, 255,     0, 255, 0, 255,     0, 0, 255, 255,
            0, 255, 255, 255,   255, 0, 255, 255,   255, 255, 0, 255,
        ]
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
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
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              )
        else { return XCTFail("Could not create test image") }

        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
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

    private enum TestError: Error {
        case decodeFailed
    }
}

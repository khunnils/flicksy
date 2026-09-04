//
//  ThumbnailServiceTests.swift
//  FlicksyTests
//

import AppKit
import XCTest
@testable import Flicksy

final class ThumbnailServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyThumbnail-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSVGThumbnailUsesIntrinsicDimensionsAndRequestedBound() async throws {
        let url = directory.appending(path: "vector.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="300" height="200" viewBox="0 0 300 200">
          <rect width="300" height="200" fill="#ff3366"/>
          <circle cx="150" cy="100" r="50" fill="#33ccff"/>
        </svg>
        """
        try XCTUnwrap(svg.data(using: .utf8)).write(to: url)

        let result = await ThumbnailService.shared.thumbnail(for: url, targetPixels: 256)
        let thumbnail = try XCTUnwrap(result)

        XCTAssertEqual(thumbnail.pixelWidth, 300)
        XCTAssertEqual(thumbnail.pixelHeight, 200)
        XCTAssertEqual(thumbnail.image.size.width, 256, accuracy: 0.5)
        XCTAssertEqual(thumbnail.image.size.height, 171, accuracy: 0.5)
        XCTAssertEqual(ThumbnailService.pixelSize(for: url), CGSize(width: 300, height: 200))

        let cgImage = try XCTUnwrap(
            thumbnail.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        )
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let centerColor = try XCTUnwrap(bitmap.colorAt(x: cgImage.width / 2, y: cgImage.height / 2))
        XCTAssertGreaterThan(centerColor.alphaComponent, 0.99)
    }
}

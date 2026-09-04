//
//  BrowserModelThumbnailSizeTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

final class BrowserModelThumbnailSizeTests: XCTestCase {
    func testThumbnailSizeAllowsCompactIconGrid() {
        XCTAssertEqual(BrowserModel.clampedThumbnailSize(48), 48)
        XCTAssertEqual(BrowserModel.clampedThumbnailSize(24), BrowserModel.minThumbnailSize)
    }

    func testThumbnailSizeStillClampsAtMaximum() {
        XCTAssertEqual(
            BrowserModel.clampedThumbnailSize(BrowserModel.maxThumbnailSize + 1),
            BrowserModel.maxThumbnailSize
        )
    }
}

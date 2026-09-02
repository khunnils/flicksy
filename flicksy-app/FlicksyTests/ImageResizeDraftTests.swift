//
//  ImageResizeDraftTests.swift
//  FlicksyTests
//

import CoreGraphics
import XCTest
@testable import Flicksy

final class ImageResizeDraftTests: XCTestCase {
    func testStartsLockedAndUnchanged() throws {
        let draft = try XCTUnwrap(ImageResizeDraft(sourceSize: CGSize(width: 1200, height: 800)))

        XCTAssertEqual(draft.widthText, "1200")
        XCTAssertEqual(draft.heightText, "800")
        XCTAssertTrue(draft.isAspectRatioLocked)
        XCTAssertFalse(draft.canApply)
    }

    func testLockedEditsScaleAndRoundOppositeDimension() throws {
        var draft = try XCTUnwrap(ImageResizeDraft(sourceSize: CGSize(width: 3, height: 2)))

        draft.setWidthText("10")
        XCTAssertEqual(draft.width, 10)
        XCTAssertEqual(draft.height, 7)
        XCTAssertTrue(draft.canApply)

        draft.setHeightText("5")
        XCTAssertEqual(draft.width, 8)
        XCTAssertEqual(draft.height, 5)
    }

    func testUnlockedEditsAllowExactIndependentDimensionsAndUpscaling() throws {
        var draft = try XCTUnwrap(ImageResizeDraft(sourceSize: CGSize(width: 100, height: 50)))
        draft.isAspectRatioLocked = false

        draft.setWidthText("2000")
        draft.setHeightText("7")

        XCTAssertEqual(draft.targetSize, CGSize(width: 2000, height: 7))
        XCTAssertTrue(draft.canApply)
    }

    func testInvalidTextCannotApply() throws {
        let invalidValues = ["", "0", "-1", "1.5", "pixels"]
        for value in invalidValues {
            var draft = try XCTUnwrap(ImageResizeDraft(sourceSize: CGSize(width: 100, height: 50)))
            draft.setWidthText(value)
            XCTAssertNil(draft.targetSize, "Expected \(value) to be invalid")
            XCTAssertFalse(draft.canApply)
        }
    }
}

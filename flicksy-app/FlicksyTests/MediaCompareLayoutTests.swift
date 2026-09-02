//
//  MediaCompareLayoutTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

final class MediaCompareLayoutTests: XCTestCase {
    func testLayoutMetadataAndAvailability() {
        XCTAssertEqual(MediaCompareLayout.oneByTwo.columns, 1)
        XCTAssertEqual(MediaCompareLayout.oneByTwo.rows, 2)
        XCTAssertEqual(MediaCompareLayout.twoByOne.capacity, 2)
        XCTAssertEqual(MediaCompareLayout.twoByTwo.capacity, 4)
        XCTAssertEqual(MediaCompareLayout.oneByThree.capacity, 3)
        XCTAssertEqual(MediaCompareLayout.threeByOne.title, "3 × 1")

        XCTAssertTrue(MediaCompareLayout.twoByOne.isAvailable(for: 2))
        XCTAssertFalse(MediaCompareLayout.oneByThree.isAvailable(for: 2))
        XCTAssertTrue(MediaCompareLayout.twoByTwo.isAvailable(for: 5))
    }

    func testAutomaticLayoutUsesCountAndOrientationMajority() {
        let portraits = [
            image("portrait-a", width: 800, height: 1200),
            image("portrait-b", width: 1000, height: 1400),
        ]
        XCTAssertEqual(
            MediaCompareLayout.automatic(for: portraits, focusedItemID: portraits[0].id),
            .twoByOne
        )

        let landscapes = [
            image("landscape-a", width: 1600, height: 900),
            image("landscape-b", width: 1400, height: 900),
        ]
        XCTAssertEqual(
            MediaCompareLayout.automatic(for: landscapes, focusedItemID: landscapes[0].id),
            .oneByTwo
        )

        let threePortraitMajority = [
            image("portrait", width: 800, height: 1200),
            image("square", width: 1000, height: 1000),
            image("landscape", width: 1600, height: 900),
        ]
        XCTAssertEqual(
            MediaCompareLayout.automatic(
                for: threePortraitMajority,
                focusedItemID: threePortraitMajority[2].id
            ),
            .threeByOne
        )

        let four = portraits + landscapes
        XCTAssertEqual(
            MediaCompareLayout.automatic(for: four, focusedItemID: four[0].id),
            .twoByTwo
        )
        XCTAssertEqual(
            MediaCompareLayout.automatic(for: four + [image("overflow")], focusedItemID: nil),
            .twoByTwo
        )
    }

    func testAutomaticLayoutTieUsesFocusThenKnownItemThenHorizontalFallback() {
        let portrait = image("portrait", width: 800, height: 1200)
        let landscape = image("landscape", width: 1600, height: 900)
        let tied = [portrait, landscape]

        XCTAssertEqual(
            MediaCompareLayout.automatic(for: tied, focusedItemID: landscape.id),
            .oneByTwo
        )
        XCTAssertEqual(
            MediaCompareLayout.automatic(for: tied, focusedItemID: portrait.id),
            .twoByOne
        )
        XCTAssertEqual(
            MediaCompareLayout.automatic(for: [landscape, image("unknown")], focusedItemID: nil),
            .oneByTwo
        )
        XCTAssertEqual(
            MediaCompareLayout.automatic(for: [image("unknown-a"), image("unknown-b")], focusedItemID: nil),
            .twoByOne
        )
    }

    func testInitialAssignmentPlacesFocusedImageFirstAndKeepsOverflow() {
        let all = ["a", "b", "c", "d", "e"]
        let assigned = MediaComparisonAssignment.initial(
            itemIDs: all,
            preferredItemID: "e",
            capacity: 4
        )
        XCTAssertEqual(assigned, ["e", "a", "b", "c"])
        XCTAssertEqual(all, ["a", "b", "c", "d", "e"])
    }

    func testResizePreservesAssignmentsAndFillsFromUnassignedItems() {
        let all = ["a", "b", "c", "d", "e"]
        let contracted = MediaComparisonAssignment.resized(
            assignments: ["e", "a", "b", "c"],
            allItemIDs: all,
            capacity: 2
        )
        XCTAssertEqual(contracted, ["e", "a"])

        let expanded = MediaComparisonAssignment.resized(
            assignments: contracted,
            allItemIDs: all,
            capacity: 4
        )
        XCTAssertEqual(expanded, ["e", "a", "b", "c"])

        let reconciled = MediaComparisonAssignment.resized(
            assignments: ["e", "missing", "b"],
            allItemIDs: all,
            capacity: 3
        )
        XCTAssertEqual(reconciled, ["e", "b", "a"])
    }

    func testDropSwapsAssignedImagesAndReplacesFromOverflow() {
        let all = ["a", "b", "c", "d", "e"]
        let swapped = MediaComparisonAssignment.assigning(
            itemID: "c",
            toSlot: 0,
            assignments: ["a", "b", "c", "d"],
            allItemIDs: all
        )
        XCTAssertEqual(swapped, ["c", "b", "a", "d"])

        let replaced = MediaComparisonAssignment.assigning(
            itemID: "e",
            toSlot: 1,
            assignments: swapped,
            allItemIDs: all
        )
        XCTAssertEqual(replaced, ["c", "e", "a", "d"])
        XCTAssertTrue(all.contains("b"))
    }

    private func image(_ name: String, width: Int? = nil, height: Int? = nil) -> MediaItem {
        MediaItem(
            url: URL(fileURLWithPath: "/tmp/\(name).png"),
            type: .image,
            name: "\(name).png",
            width: width,
            height: height
        )
    }
}

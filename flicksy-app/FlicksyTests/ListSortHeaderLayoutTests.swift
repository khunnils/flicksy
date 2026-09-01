//
//  ListSortHeaderLayoutTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

final class ListSortHeaderLayoutTests: XCTestCase {
    func testAllListKindClickDoesNotMapToDateModified() {
        let layout = ListSortHeaderLayout(
            gutter: 28,
            spacing: 12,
            horizontalPadding: 8,
            columns: [
                (.name, 280),
                (.kind, 140),
                (.added, 110),
                (.modified, 110),
                (.duration, 80),
                (.dimensions, 100),
                (.size, 90),
            ]
        )

        // padding 8 + gutter 28 + spacing 12 = 48 (Name)
        // Name 280 + spacing 12 = Kind at 340
        XCTAssertEqual(layout.sortKey(atX: 48), .name)
        XCTAssertEqual(layout.sortKey(atX: 340), .kind)
        XCTAssertEqual(layout.sortKey(atX: 400), .kind)
        XCTAssertEqual(layout.sortKey(atX: 479), .kind)
        XCTAssertEqual(layout.sortKey(atX: 492), .added)
        XCTAssertEqual(layout.sortKey(atX: 614), .modified)
        XCTAssertEqual(layout.sortKey(atX: 980), .size)
        XCTAssertNil(layout.sortKey(atX: 10), "Clicks in the leading gutter should not sort")
    }
}

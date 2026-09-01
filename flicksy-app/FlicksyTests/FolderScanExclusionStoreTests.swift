//
//  FolderScanExclusionStoreTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

final class FolderScanExclusionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "FlicksyExclusion-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testExcludePersistsAndRebuildsPolicy() {
        let store = FolderScanExclusionStore(defaults: defaults)
        let url = URL(fileURLWithPath: "/Users/me/Photos/Renders", isDirectory: true)
        store.exclude(url)

        XCTAssertTrue(store.policy.excludes(url))
        XCTAssertEqual(store.hiddenCount(under: URL(fileURLWithPath: "/Users/me/Photos")), 1)

        let reopened = FolderScanExclusionStore(defaults: defaults)
        XCTAssertTrue(reopened.policy.excludes(url))
    }

    func testRestoreHiddenClearsDescendantsOnly() {
        let store = FolderScanExclusionStore(defaults: defaults)
        let photos = URL(fileURLWithPath: "/Users/me/Photos", isDirectory: true)
        let renders = URL(fileURLWithPath: "/Users/me/Photos/Renders", isDirectory: true)
        let other = URL(fileURLWithPath: "/Users/me/Music/Stems", isDirectory: true)
        store.exclude(renders)
        store.exclude(other)

        XCTAssertEqual(store.restoreHidden(under: photos), 1)
        XCTAssertFalse(store.policy.excludes(renders))
        XCTAssertTrue(store.policy.excludes(other))
    }
}
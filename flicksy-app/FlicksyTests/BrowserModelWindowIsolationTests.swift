//
//  BrowserModelWindowIsolationTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

@MainActor
final class BrowserModelWindowIsolationTests: XCTestCase {
    func testBrowserWindowsKeepNavigationAndInteractionStateIndependent() {
        let defaults = UserDefaults(suiteName: "BrowserModelWindowIsolationTests")!
        defaults.removePersistentDomain(forName: "BrowserModelWindowIsolationTests")
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flicksy-window-isolation-(UUID().uuidString).sqlite")
        let modelA = BrowserModel(
            onboardingStore: OnboardingStore(defaults: defaults),
            libraryRepository: LibraryRepository(databaseURL: databaseURL)
        )
        let modelB = BrowserModel(
            onboardingStore: OnboardingStore(defaults: defaults),
            libraryRepository: LibraryRepository(databaseURL: databaseURL)
        )
        let originalTab = modelB.libraryTab
        let originalThumbnailSize = modelB.thumbnailSize

        modelA.selectedSource = .favorites
        modelA.libraryTab = .audio
        modelA.searchQuery = "portrait"
        modelA.isQuickGotoPresented = true
        modelA.thumbnailSize = 96

        XCTAssertEqual(modelA.selectedSource, .favorites)
        XCTAssertEqual(modelA.libraryTab, .audio)
        XCTAssertEqual(modelA.searchQuery, "portrait")
        XCTAssertTrue(modelA.isQuickGotoPresented)
        XCTAssertEqual(modelA.thumbnailSize, 96)

        XCTAssertNil(modelB.selectedSource)
        XCTAssertEqual(modelB.libraryTab, originalTab)
        XCTAssertEqual(modelB.searchQuery, "")
        XCTAssertFalse(modelB.isQuickGotoPresented)
        XCTAssertEqual(modelB.thumbnailSize, originalThumbnailSize)
    }
}

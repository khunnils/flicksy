//
//  OnboardingStoreTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

final class OnboardingStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "FlicksyOnboarding-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testFreshDefaultsPresentOnboarding() {
        let store = OnboardingStore(defaults: defaults)
        XCTAssertTrue(store.shouldPresent)
    }

    func testCompletedCurrentVersionDoesNotPresent() {
        let store = OnboardingStore(defaults: defaults)
        store.markCompleted()
        XCTAssertFalse(store.shouldPresent)
    }

    func testOlderVersionPresentsAgain() {
        defaults.set(OnboardingStore.currentVersion - 1, forKey: "completedOnboardingVersion")
        let store = OnboardingStore(defaults: defaults)
        XCTAssertTrue(store.shouldPresent)
    }

    func testCompletionPersistsAcrossStoreInstances() {
        OnboardingStore(defaults: defaults).markCompleted()
        let reopened = OnboardingStore(defaults: defaults)
        XCTAssertFalse(reopened.shouldPresent)
    }
}

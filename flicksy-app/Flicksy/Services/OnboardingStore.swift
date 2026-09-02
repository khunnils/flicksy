//
//  OnboardingStore.swift
//  Flicksy
//

import Foundation

/// Persists which version of Flicksy's welcome flow the user has completed.
///
/// Keeping a version instead of a boolean lets a future, materially different
/// onboarding experience be shown once by incrementing `currentVersion`.
final class OnboardingStore {
    static let currentVersion = 1

    private let defaults: UserDefaults
    private let defaultsKey: String

    init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "completedOnboardingVersion"
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
    }

    var shouldPresent: Bool {
        defaults.integer(forKey: defaultsKey) < Self.currentVersion
    }

    func markCompleted() {
        defaults.set(Self.currentVersion, forKey: defaultsKey)
    }
}

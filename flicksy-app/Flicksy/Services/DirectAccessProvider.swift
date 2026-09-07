//
//  DirectAccessProvider.swift
//  Flicksy
//

#if DIRECT_DISTRIBUTION
import AppKit
import Foundation

struct DirectAccessConfiguration: Equatable {
    let appStoreURL: URL?

    static func fromBundle(_ bundle: Bundle = .main) -> DirectAccessConfiguration {
        let value = bundle.object(forInfoDictionaryKey: "FlicksyAppStoreURL") as? String
        guard let value, !value.hasPrefix("$(") else {
            return DirectAccessConfiguration(appStoreURL: nil)
        }
        return DirectAccessConfiguration(appStoreURL: URL(string: value))
    }
}

@MainActor
final class DirectAccessProvider: AccessProviding {
    let channel = DistributionChannel.direct

    static let trialDuration: TimeInterval = 14 * 24 * 60 * 60
    static let clockTolerance: TimeInterval = 5 * 60
    static let lastSeenWriteInterval: TimeInterval = 15 * 60

    private struct TrialRecord: Codable, Equatable {
        let startedAt: Date
        var lastSeenAt: Date
    }

    private let configuration: DirectAccessConfiguration
    private let secureStore: SecureStoring
    private let openURL: (URL) -> Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let trialKey = "trial"

    convenience init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "me.flicksy.app"
        self.init(
            configuration: .fromBundle(),
            secureStore: KeychainSecureStore(service: "\(bundleID).access.direct"),
            openURL: { NSWorkspace.shared.open($0) }
        )
    }

    init(
        configuration: DirectAccessConfiguration,
        secureStore: SecureStoring,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.configuration = configuration
        self.secureStore = secureStore
        self.openURL = openURL
    }

    func currentSnapshot(now: Date) async throws -> AccessSnapshot {
        try localSnapshot(now: now)
    }

    func startTrial(now: Date) async throws -> AccessSnapshot {
        if try load(TrialRecord.self, key: trialKey) == nil {
            try save(TrialRecord(startedAt: now, lastSeenAt: now), key: trialKey)
        }
        return try localSnapshot(now: now)
    }

    func purchase(now: Date) async throws -> AccessSnapshot {
        guard let appStoreURL = configuration.appStoreURL else {
            throw AccessActionError.configuration("Flicksy is not available on the App Store yet. Please check back soon.")
        }
        guard openURL(appStoreURL) else {
            throw AccessActionError.service("The App Store listing could not be opened. Please try again.")
        }
        return try localSnapshot(now: now)
    }

    func restore(now: Date) async throws -> AccessSnapshot {
        try localSnapshot(now: now)
    }

#if TEST_ENVIRONMENT
    func resetTrialForTesting(now: Date) async throws -> AccessSnapshot {
        try secureStore.remove(trialKey)
        return try localSnapshot(now: now)
    }

    func expireTrialForTesting(now: Date) async throws -> AccessSnapshot {
        try save(
            TrialRecord(startedAt: now.addingTimeInterval(-Self.trialDuration - 1), lastSeenAt: now),
            key: trialKey
        )
        return try localSnapshot(now: now)
    }
#endif

    private func localSnapshot(now: Date) throws -> AccessSnapshot {
        guard var trial = try load(TrialRecord.self, key: trialKey) else {
            return AccessSnapshot(state: .trialAvailable)
        }
        if now.addingTimeInterval(Self.clockTolerance) < trial.lastSeenAt {
            return AccessSnapshot(
                state: .recoverableError(message: AccessActionError.clockInvalid.localizedDescription, allowsAccess: false)
            )
        }
        if now.timeIntervalSince(trial.lastSeenAt) >= Self.lastSeenWriteInterval {
            trial.lastSeenAt = now
            try save(trial, key: trialKey)
        }
        let expiresAt = trial.startedAt.addingTimeInterval(Self.trialDuration)
        return AccessSnapshot(state: now < expiresAt ? .trialActive(expiresAt: expiresAt) : .expired)
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let data = try secureStore.data(for: key) else { return nil }
        return try decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) throws {
        try secureStore.set(try encoder.encode(value), for: key)
    }
}
#endif

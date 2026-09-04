//
//  DirectAccessProvider.swift
//  Flicksy
//

#if DIRECT_DISTRIBUTION
import AppKit
import Foundation

struct DirectAccessConfiguration: Equatable {
    let checkoutURL: URL?
    let licenseAPIURL: URL?
    let purchasePrice: String

    static let defaultLicenseAPIURL = URL(string: "https://flicksy.me/api/licenses")!

    static func fromBundle(_ bundle: Bundle = .main) -> DirectAccessConfiguration {
        let checkout = bundle.object(forInfoDictionaryKey: "FlicksyCheckoutURL") as? String
        let licenseAPI = bundle.object(forInfoDictionaryKey: "FlicksyLicenseAPIURL") as? String
        return DirectAccessConfiguration(
            checkoutURL: checkout.flatMap(URL.init(string:)),
            licenseAPIURL: normalizedLicenseBaseURL(licenseAPI.flatMap(URL.init(string:)) ?? defaultLicenseAPIURL),
            purchasePrice: bundle.object(forInfoDictionaryKey: "FlicksyPurchasePrice") as? String ?? "$19"
        )
    }

    var isLicenseConfigured: Bool {
        licenseAPIURL != nil
    }

    private static func normalizedLicenseBaseURL(_ url: URL) -> URL? {
        let actions = ["activate", "validate", "deactivate"]
        guard !actions.contains(url.lastPathComponent.lowercased()) else { return nil }
        return url
    }
}

@MainActor
final class DirectAccessProvider: AccessProviding {
    let channel = DistributionChannel.direct

    static let trialDuration: TimeInterval = 14 * 24 * 60 * 60
    static let validationInterval: TimeInterval = 7 * 24 * 60 * 60
    static let clockTolerance: TimeInterval = 5 * 60
    static let lastSeenWriteInterval: TimeInterval = 15 * 60

    private struct TrialRecord: Codable, Equatable {
        let startedAt: Date
        var lastSeenAt: Date
    }

    private struct LicenseRecord: Codable, Equatable {
        let key: String
        let instanceID: String
        let purchasedAt: Date
        var lastValidatedAt: Date
        var activationUsage: Int?
        var activationLimit: Int?
    }

    private struct DeviceRecord: Codable, Equatable {
        let label: String
    }

    private struct LicenseResponse: Decodable {
        let ok: Bool
        let status: String?
        let instanceID: String?
        let createdAt: String?
        let activationUsage: Int?
        let activationLimit: Int?
        let error: String?
        let errorCode: String?

        enum CodingKeys: String, CodingKey {
            case ok, status, error
            case instanceID = "instance_id"
            case createdAt = "created_at"
            case activationUsage = "activation_usage"
            case activationLimit = "activation_limit"
            case errorCode = "error_code"
        }

        var hasUsableStatus: Bool {
            status == "active" || status == "inactive"
        }
    }

    private let configuration: DirectAccessConfiguration
    private let secureStore: SecureStoring
    private let session: URLSession
    private let openURL: (URL) -> Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let trialKey = "trial"
    private let licenseKey = "license"
    private let deviceKey = "device"

    convenience init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "cloudedminds.Flicksy"
        self.init(
            configuration: .fromBundle(),
            secureStore: KeychainSecureStore(service: "\(bundleID).access.direct")
        )
    }

    init(
        configuration: DirectAccessConfiguration,
        secureStore: SecureStoring,
        session: URLSession = .shared,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.configuration = configuration
        self.secureStore = secureStore
        self.session = session
        self.openURL = openURL
    }

    func currentSnapshot(now: Date) async throws -> AccessSnapshot {
        try localSnapshot(now: now)
    }

    func startTrial(now: Date) async throws -> AccessSnapshot {
        if try load(LicenseRecord.self, key: licenseKey) != nil {
            return try localSnapshot(now: now)
        }

        if try load(TrialRecord.self, key: trialKey) == nil {
            try save(TrialRecord(startedAt: now, lastSeenAt: now), key: trialKey)
        }
        return try localSnapshot(now: now)
    }

    func purchase(now: Date) async throws -> AccessSnapshot {
        guard let checkoutURL = configuration.checkoutURL else {
            throw AccessActionError.configuration("The Flicksy checkout URL has not been configured.")
        }
        guard openURL(checkoutURL) else {
            throw AccessActionError.service("The checkout could not be opened in your browser.")
        }
        return try localSnapshot(now: now)
    }

    func activate(licenseKey rawKey: String, now: Date) async throws -> AccessSnapshot {
        try requireConfiguredLicense()
        let normalizedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedKey.count >= 12 else {
            throw AccessActionError.invalidLicense("Enter the complete license key from your Flicksy receipt.")
        }

        let device = try deviceRecord()
        let response = try await request(
            endpoint: "activate",
            fields: ["key": normalizedKey, "instance_name": device.label]
        )
        try throwIfFailed(response, fallback: "This license could not be activated.")

        guard response.hasUsableStatus,
              let instanceID = response.instanceID,
              let createdAt = response.createdAt,
              let purchasedAt = Self.parseDate(createdAt)
        else {
            throw AccessActionError.invalidLicense("The license response was incomplete. Please try again.")
        }

        try save(
            LicenseRecord(
                key: normalizedKey,
                instanceID: instanceID,
                purchasedAt: purchasedAt,
                lastValidatedAt: now,
                activationUsage: response.activationUsage,
                activationLimit: response.activationLimit
            ),
            key: licenseKey
        )
        return try localSnapshot(now: now)
    }

    func restore(now: Date) async throws -> AccessSnapshot {
        try localSnapshot(now: now)
    }

    func deactivate(now: Date) async throws -> AccessSnapshot {
        guard let record = try load(LicenseRecord.self, key: licenseKey) else {
            return try localSnapshot(now: now)
        }

        let response = try await request(
            endpoint: "deactivate",
            fields: ["key": record.key, "instance_id": record.instanceID]
        )
        try throwIfFailed(response, fallback: "This Mac could not be deactivated.")
        try secureStore.remove(licenseKey)
        return try localSnapshot(now: now)
    }

    func revalidateIfNeeded(now: Date) async throws -> AccessSnapshot? {
        guard var record = try load(LicenseRecord.self, key: licenseKey),
              now.timeIntervalSince(record.lastValidatedAt) >= Self.validationInterval
        else { return nil }

        let response = try await request(
            endpoint: "validate",
            fields: ["key": record.key, "instance_id": record.instanceID]
        )
        if response.errorCode == "service" {
            throw AccessActionError.service(
                response.error ?? "The licensing service is unavailable. Try again in a moment."
            )
        }

        guard response.ok, response.hasUsableStatus else {
            try secureStore.remove(licenseKey)
            return try localSnapshot(now: now)
        }

        record.lastValidatedAt = now
        record.activationUsage = response.activationUsage
        record.activationLimit = response.activationLimit
        try save(record, key: licenseKey)
        return try localSnapshot(now: now)
    }

#if TEST_ENVIRONMENT
    func resetTrialForTesting(now: Date) async throws -> AccessSnapshot {
        try secureStore.remove(trialKey)
        return try localSnapshot(now: now)
    }

    func expireTrialForTesting(now: Date) async throws -> AccessSnapshot {
        try save(
            TrialRecord(
                startedAt: now.addingTimeInterval(-Self.trialDuration - 1),
                lastSeenAt: now
            ),
            key: trialKey
        )
        return try localSnapshot(now: now)
    }
#endif

    private func localSnapshot(now: Date) throws -> AccessSnapshot {
        if let license = try load(LicenseRecord.self, key: licenseKey) {
            return AccessSnapshot(
                state: .licensed,
                purchasePrice: configuration.purchasePrice,
                purchasedAt: license.purchasedAt,
                activationUsage: license.activationUsage,
                activationLimit: license.activationLimit
            )
        }

        guard var trial = try load(TrialRecord.self, key: trialKey) else {
            return AccessSnapshot(state: .trialAvailable, purchasePrice: configuration.purchasePrice)
        }

        if now.addingTimeInterval(Self.clockTolerance) < trial.lastSeenAt {
            return AccessSnapshot(
                state: .recoverableError(
                    message: AccessActionError.clockInvalid.localizedDescription,
                    allowsAccess: false
                ),
                purchasePrice: configuration.purchasePrice
            )
        }

        if now.timeIntervalSince(trial.lastSeenAt) >= Self.lastSeenWriteInterval {
            trial.lastSeenAt = now
            try save(trial, key: trialKey)
        }

        let expiresAt = trial.startedAt.addingTimeInterval(Self.trialDuration)
        return AccessSnapshot(
            state: now < expiresAt ? .trialActive(expiresAt: expiresAt) : .expired,
            purchasePrice: configuration.purchasePrice
        )
    }

    private func requireConfiguredLicense() throws {
        guard configuration.isLicenseConfigured else {
            throw AccessActionError.configuration("Direct licensing has not been configured for this build.")
        }
    }

    private func deviceRecord() throws -> DeviceRecord {
        if let existing = try load(DeviceRecord.self, key: deviceKey) { return existing }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).uppercased()
        let record = DeviceRecord(label: "Flicksy Mac \(suffix)")
        try save(record, key: deviceKey)
        return record
    }

    private func request(endpoint: String, fields: [String: String]) async throws -> LicenseResponse {
        guard let base = configuration.licenseAPIURL else {
            throw AccessActionError.configuration("The licensing service URL is invalid.")
        }
        let url = base.appendingPathComponent(endpoint)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)

        let (data, response) = try await session.data(for: request)
        guard response is HTTPURLResponse else {
            throw AccessActionError.service("The licensing service returned an invalid response.")
        }

        if let decoded = try? decoder.decode(LicenseResponse.self, from: data) {
            return decoded
        }
        throw AccessActionError.service("The licensing service is unavailable. Try again in a moment.")
    }

    private func throwIfFailed(_ response: LicenseResponse, fallback: String) throws {
        guard !response.ok else { return }
        switch response.errorCode {
        case "limit":
            throw AccessActionError.activationLimitReached
        case "invalid", "not_found":
            throw AccessActionError.invalidLicense(response.error ?? fallback)
        default:
            throw AccessActionError.service(response.error ?? fallback)
        }
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let data = try secureStore.data(for: key) else { return nil }
        return try decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) throws {
        try secureStore.set(try encoder.encode(value), for: key)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}
#endif

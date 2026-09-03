//
//  DirectAccessProvider.swift
//  Flicksy
//

#if DIRECT_DISTRIBUTION
import AppKit
import Foundation

struct DirectAccessConfiguration: Equatable {
    let checkoutURL: URL?
    let lemonStoreID: Int
    let lemonProductID: Int
    let lemonVariantID: Int
    let purchasePrice: String

    static func fromBundle(_ bundle: Bundle = .main) -> DirectAccessConfiguration {
        func integer(_ key: String) -> Int {
            if let value = bundle.object(forInfoDictionaryKey: key) as? NSNumber {
                return value.intValue
            }
            if let value = bundle.object(forInfoDictionaryKey: key) as? String {
                return Int(value) ?? 0
            }
            return 0
        }

        let checkout = bundle.object(forInfoDictionaryKey: "FlicksyCheckoutURL") as? String
        return DirectAccessConfiguration(
            checkoutURL: checkout.flatMap(URL.init(string:)),
            lemonStoreID: integer("FlicksyLemonStoreID"),
            lemonProductID: integer("FlicksyLemonProductID"),
            lemonVariantID: integer("FlicksyLemonVariantID"),
            purchasePrice: bundle.object(forInfoDictionaryKey: "FlicksyPurchasePrice") as? String ?? "$19"
        )
    }

    var isLicenseConfigured: Bool {
        lemonStoreID > 0 && lemonProductID > 0 && lemonVariantID > 0
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

    private struct LemonResponse: Decodable {
        let activated: Bool?
        let deactivated: Bool?
        let valid: Bool?
        let error: String?
        let licenseKey: LemonLicense?
        let instance: LemonInstance?
        let meta: LemonMeta?

        enum CodingKeys: String, CodingKey {
            case activated, deactivated, valid, error, instance, meta
            case licenseKey = "license_key"
        }
    }

    private struct LemonLicense: Decodable {
        let status: String
        let activationLimit: Int?
        let activationUsage: Int?
        let createdAt: String

        enum CodingKeys: String, CodingKey {
            case status
            case activationLimit = "activation_limit"
            case activationUsage = "activation_usage"
            case createdAt = "created_at"
        }
    }

    private struct LemonInstance: Decodable {
        let id: String
    }

    private struct LemonMeta: Decodable {
        let storeID: Int
        let productID: Int
        let variantID: Int

        enum CodingKeys: String, CodingKey {
            case storeID = "store_id"
            case productID = "product_id"
            case variantID = "variant_id"
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
        self.init(
            configuration: .fromBundle(),
            secureStore: KeychainSecureStore()
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
            fields: ["license_key": normalizedKey, "instance_name": device.label]
        )

        guard response.activated == true else {
            if response.error?.localizedCaseInsensitiveContains("activation limit") == true {
                throw AccessActionError.activationLimitReached
            }
            throw AccessActionError.invalidLicense(response.error ?? "This license could not be activated.")
        }

        try validateProduct(response.meta)
        guard let license = response.licenseKey,
              license.status == "active" || license.status == "inactive",
              let instanceID = response.instance?.id,
              let purchasedAt = Self.parseDate(license.createdAt)
        else {
            throw AccessActionError.invalidLicense("The license response was incomplete. Please try again.")
        }

        try save(
            LicenseRecord(
                key: normalizedKey,
                instanceID: instanceID,
                purchasedAt: purchasedAt,
                lastValidatedAt: now,
                activationUsage: license.activationUsage,
                activationLimit: license.activationLimit
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
            fields: ["license_key": record.key, "instance_id": record.instanceID]
        )
        guard response.deactivated == true else {
            throw AccessActionError.service(response.error ?? "This Mac could not be deactivated.")
        }
        try secureStore.remove(licenseKey)
        return try localSnapshot(now: now)
    }

    func revalidateIfNeeded(now: Date) async throws -> AccessSnapshot? {
        guard var record = try load(LicenseRecord.self, key: licenseKey),
              now.timeIntervalSince(record.lastValidatedAt) >= Self.validationInterval
        else { return nil }

        let response = try await request(
            endpoint: "validate",
            fields: ["license_key": record.key, "instance_id": record.instanceID]
        )
        do {
            try validateProduct(response.meta)
        } catch {
            // A successful vendor response for another product must never keep
            // a cached Flicksy entitlement alive.
            try secureStore.remove(licenseKey)
            return try localSnapshot(now: now)
        }

        guard response.valid == true,
              let license = response.licenseKey,
              license.status == "active" || license.status == "inactive"
        else {
            try secureStore.remove(licenseKey)
            return try localSnapshot(now: now)
        }

        record.lastValidatedAt = now
        record.activationUsage = license.activationUsage
        record.activationLimit = license.activationLimit
        try save(record, key: licenseKey)
        return try localSnapshot(now: now)
    }

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

    private func request(endpoint: String, fields: [String: String]) async throws -> LemonResponse {
        guard let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/\(endpoint)") else {
            throw AccessActionError.configuration("The licensing service URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AccessActionError.service("The licensing service returned an invalid response.")
        }

        let decoded = try? decoder.decode(LemonResponse.self, from: data)
        guard (200..<300).contains(httpResponse.statusCode), let decoded else {
            throw AccessActionError.service(
                decoded?.error ?? "The licensing service is unavailable. Try again in a moment."
            )
        }
        return decoded
    }

    private func validateProduct(_ meta: LemonMeta?) throws {
        guard let meta,
              meta.storeID == configuration.lemonStoreID,
              meta.productID == configuration.lemonProductID,
              meta.variantID == configuration.lemonVariantID
        else {
            throw AccessActionError.invalidLicense("This key is not a Flicksy license.")
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

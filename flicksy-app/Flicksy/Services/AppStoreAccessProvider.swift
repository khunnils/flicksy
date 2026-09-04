//
//  AppStoreAccessProvider.swift
//  Flicksy
//

#if APP_STORE_DISTRIBUTION
import Foundation
import StoreKit

struct AppStoreAccessConfiguration: Equatable, Sendable {
    let bundleID: String
    let appID: UInt64?

    static func fromBundle(_ bundle: Bundle = .main) -> AppStoreAccessConfiguration {
        let rawAppID = bundle.object(forInfoDictionaryKey: "FlicksyAppStoreAppID") as? String
        return AppStoreAccessConfiguration(
            bundleID: bundle.bundleIdentifier ?? "",
            appID: rawAppID.flatMap(UInt64.init)
        )
    }
}

struct VerifiedAppPurchase: Equatable, Codable, Sendable {
    let bundleID: String
    let appID: UInt64?
    let appTransactionID: String
    let originalPurchaseDate: Date
    let revocationDate: Date?
}

enum AppPurchaseVerification: Sendable {
    case verified(VerifiedAppPurchase)
    case unverified
}

protocol AppPurchaseVerifying: Sendable {
    func current() async throws -> AppPurchaseVerification
    func refresh() async throws -> AppPurchaseVerification
}

struct StoreKitAppPurchaseVerifier: AppPurchaseVerifying {
    func current() async throws -> AppPurchaseVerification {
        map(try await AppTransaction.shared)
    }

    func refresh() async throws -> AppPurchaseVerification {
        map(try await AppTransaction.refresh())
    }

    private func map(_ result: VerificationResult<AppTransaction>) -> AppPurchaseVerification {
        switch result {
        case .verified(let transaction):
            return .verified(
                VerifiedAppPurchase(
                    bundleID: transaction.bundleID,
                    appID: transaction.appID,
                    appTransactionID: transaction.appTransactionID,
                    originalPurchaseDate: transaction.originalPurchaseDate,
                    revocationDate: Self.revocationDate(from: transaction.jsonRepresentation)
                )
            )
        case .unverified:
            return .unverified
        }
    }

    // StoreKit adds the paid-app revocation field to AppTransaction on newer
    // systems. Reading the already verified JSON keeps macOS 15 builds able to
    // reject it without weakening the deployment target.
    private static func revocationDate(from json: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }
        let raw = object["revocationDate"] ?? object["revocation_date"]
        if let milliseconds = raw as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        guard let value = raw as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

@MainActor
final class AppStoreAccessProvider: AccessProviding {
    let channel = DistributionChannel.appStore

    private let configuration: AppStoreAccessConfiguration
    private let verifier: AppPurchaseVerifying
    private let secureStore: SecureStoring
    private let cacheKey = "verified-app-purchase"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    convenience init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "cloudedminds.Flicksy"
        self.init(
            configuration: .fromBundle(),
            verifier: StoreKitAppPurchaseVerifier(),
            secureStore: KeychainSecureStore(service: "\(bundleID).access.appstore")
        )
    }

    init(
        configuration: AppStoreAccessConfiguration,
        verifier: AppPurchaseVerifying,
        secureStore: SecureStoring
    ) {
        self.configuration = configuration
        self.verifier = verifier
        self.secureStore = secureStore
    }

    func currentSnapshot(now: Date) async throws -> AccessSnapshot {
        do {
            return try snapshot(from: try await verifier.current())
        } catch let error as AccessActionError {
            throw error
        } catch {
            if let cached = try loadCachedPurchase(), isExpected(cached), cached.revocationDate == nil {
                return licensedSnapshot(cached)
            }
            throw AccessActionError.service(
                "Flicksy could not read the App Store purchase. Connect to the internet and choose Verify Purchase."
            )
        }
    }

    func startTrial(now: Date) async throws -> AccessSnapshot {
        throw AccessActionError.configuration("The paid Mac App Store version does not include a trial.")
    }

    func purchase(now: Date) async throws -> AccessSnapshot {
        throw AccessActionError.configuration("Flicksy is purchased upfront from the Mac App Store.")
    }

    func activate(licenseKey: String, now: Date) async throws -> AccessSnapshot {
        throw AccessActionError.configuration("License keys are available only in the direct version of Flicksy.")
    }

    func restore(now: Date) async throws -> AccessSnapshot {
        try snapshot(from: try await verifier.refresh())
    }

    func deactivate(now: Date) async throws -> AccessSnapshot {
        throw AccessActionError.configuration("Mac App Store purchases cannot be deactivated from Flicksy.")
    }

    private func snapshot(from result: AppPurchaseVerification) throws -> AccessSnapshot {
        guard configuration.appID != nil, !configuration.bundleID.isEmpty else {
            throw AccessActionError.configuration("This build is missing its App Store identity.")
        }
        guard case .verified(let purchase) = result else {
            try? secureStore.remove(cacheKey)
            throw AccessActionError.unverifiedPurchase
        }
        guard isExpected(purchase) else {
            try? secureStore.remove(cacheKey)
            throw AccessActionError.unverifiedPurchase
        }
        guard purchase.revocationDate == nil else {
            try? secureStore.remove(cacheKey)
            throw AccessActionError.appPurchaseRevoked
        }

        try secureStore.set(encoder.encode(purchase), for: cacheKey)
        return licensedSnapshot(purchase)
    }

    private func isExpected(_ purchase: VerifiedAppPurchase) -> Bool {
        purchase.bundleID == configuration.bundleID && purchase.appID == configuration.appID
    }

    private func licensedSnapshot(_ purchase: VerifiedAppPurchase) -> AccessSnapshot {
        AccessSnapshot(
            state: .licensed,
            purchasePrice: "$19",
            purchasedAt: purchase.originalPurchaseDate
        )
    }

    private func loadCachedPurchase() throws -> VerifiedAppPurchase? {
        guard let data = try secureStore.data(for: cacheKey) else { return nil }
        return try decoder.decode(VerifiedAppPurchase.self, from: data)
    }
}
#endif

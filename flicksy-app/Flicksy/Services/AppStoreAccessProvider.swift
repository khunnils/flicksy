//
//  AppStoreAccessProvider.swift
//  Flicksy
//

#if APP_STORE_DISTRIBUTION
import Foundation
import StoreKit

@MainActor
final class AppStoreAccessProvider: AccessProviding {
    let channel = DistributionChannel.appStore

    static let trialProductID = "cloudedminds.Flicksy.trial14"
    static let lifetimeProductID = "cloudedminds.Flicksy.lifetime"
    static let trialDuration: TimeInterval = 14 * 24 * 60 * 60

    private var products: [String: Product] = [:]
    private var verifiedPurchases: [String: Transaction] = [:]
    private var updatesTask: Task<Void, Never>?

    deinit {
        updatesTask?.cancel()
    }

    func currentSnapshot(now: Date) async throws -> AccessSnapshot {
        // Product metadata is useful for localized pricing, but an App Store
        // outage must not hide an entitlement that is already on the receipt.
        try? await loadProductsIfNeeded()
        return await entitlementSnapshot(now: now)
    }

    func startTrial(now: Date) async throws -> AccessSnapshot {
        try await purchaseProduct(id: Self.trialProductID)
        return await entitlementSnapshot(now: now)
    }

    func purchase(now: Date) async throws -> AccessSnapshot {
        try await purchaseProduct(id: Self.lifetimeProductID)
        return await entitlementSnapshot(now: now)
    }

    func activate(licenseKey: String, now: Date) async throws -> AccessSnapshot {
        throw AccessActionError.configuration("License keys are available only in the direct version of Flicksy.")
    }

    func restore(now: Date) async throws -> AccessSnapshot {
        try await AppStore.sync()
        return await entitlementSnapshot(now: now)
    }

    func deactivate(now: Date) async throws -> AccessSnapshot {
        throw AccessActionError.configuration("App Store purchases cannot be deactivated from Flicksy.")
    }

    func observeChanges(_ handler: @escaping @MainActor () -> Void) {
        updatesTask?.cancel()
        updatesTask = Task {
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                if case .verified(let transaction) = result {
                    if transaction.revocationDate == nil {
                        verifiedPurchases[transaction.productID] = transaction
                    } else {
                        verifiedPurchases.removeValue(forKey: transaction.productID)
                    }
                    await transaction.finish()
                    handler()
                }
            }
        }
    }

    private func loadProductsIfNeeded() async throws {
        guard products.isEmpty else { return }
        let loaded = try await Product.products(for: [Self.trialProductID, Self.lifetimeProductID])
        products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    }

    private func purchaseProduct(id: String) async throws {
        try await loadProductsIfNeeded()
        guard let product = products[id] else {
            throw AccessActionError.configuration("This Flicksy purchase is not available from the App Store.")
        }

        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw AccessActionError.unverifiedPurchase
            }
            verifiedPurchases[transaction.productID] = transaction
            await transaction.finish()
        case .pending:
            throw AccessActionError.purchasePending
        case .userCancelled:
            throw AccessActionError.purchaseCancelled
        @unknown default:
            throw AccessActionError.service("The App Store returned an unknown purchase result.")
        }
    }

    private func entitlementSnapshot(now: Date) async -> AccessSnapshot {
        var trialPurchaseDate: Date?
        var lifetimePurchaseDate: Date?

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil
            else { continue }

            verifiedPurchases[transaction.productID] = transaction

            record(transaction, trialPurchaseDate: &trialPurchaseDate, lifetimePurchaseDate: &lifetimePurchaseDate)
        }

        // StoreKit can deliver the verified purchase result before the updated
        // transaction appears in currentEntitlements. Keep that verified result
        // for the lifetime of this provider so the UI unlocks immediately.
        for transaction in verifiedPurchases.values where transaction.revocationDate == nil {
            record(transaction, trialPurchaseDate: &trialPurchaseDate, lifetimePurchaseDate: &lifetimePurchaseDate)
        }

        let price = products[Self.lifetimeProductID]?.displayPrice
        if let lifetimePurchaseDate {
            return AccessSnapshot(
                state: .licensed,
                purchasePrice: price,
                purchasedAt: lifetimePurchaseDate
            )
        }

        if let trialPurchaseDate {
            let expiresAt = trialPurchaseDate.addingTimeInterval(Self.trialDuration)
            return AccessSnapshot(
                state: now < expiresAt ? .trialActive(expiresAt: expiresAt) : .expired,
                purchasePrice: price
            )
        }

        return AccessSnapshot(state: .trialAvailable, purchasePrice: price)
    }

    private func record(
        _ transaction: Transaction,
        trialPurchaseDate: inout Date?,
        lifetimePurchaseDate: inout Date?
    ) {

        switch transaction.productID {
            case Self.lifetimeProductID:
                lifetimePurchaseDate = min(lifetimePurchaseDate ?? transaction.purchaseDate, transaction.purchaseDate)
            case Self.trialProductID:
                trialPurchaseDate = min(trialPurchaseDate ?? transaction.purchaseDate, transaction.purchaseDate)
            default:
                break
        }
    }
}
#endif

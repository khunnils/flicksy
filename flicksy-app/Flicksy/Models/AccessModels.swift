//
//  AccessModels.swift
//  Flicksy
//

import Foundation

enum DistributionChannel: String, Sendable {
    case direct
    case appStore
}

enum AccessState: Equatable, Sendable {
    case loading
    case trialAvailable
    case trialActive(expiresAt: Date)
    case licensed
    case expired
    case recoverableError(message: String, allowsAccess: Bool)

    var allowsAccess: Bool {
        switch self {
        case .trialActive, .licensed:
            true
        case .recoverableError(_, let allowsAccess):
            allowsAccess
        case .loading, .trialAvailable, .expired:
            false
        }
    }
}

struct AccessSnapshot: Equatable, Sendable {
    let state: AccessState
    var purchasePrice: String?
    var purchasedAt: Date?
    var activationUsage: Int?
    var activationLimit: Int?
}

enum AccessActionError: LocalizedError, Equatable {
    case configuration(String)
    case invalidLicense(String)
    case activationLimitReached
    case clockInvalid
    case purchasePending
    case purchaseCancelled
    case unverifiedPurchase
    case service(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .invalidLicense(let message), .service(let message):
            message
        case .activationLimitReached:
            "This license is already active on the maximum number of Macs. Deactivate another Mac or contact support."
        case .clockInvalid:
            "Flicksy could not verify the trial because the system clock moved backwards. Turn on automatic date and time, then try again."
        case .purchasePending:
            "The purchase is waiting for approval. Flicksy will unlock automatically when it completes."
        case .purchaseCancelled:
            nil
        case .unverifiedPurchase:
            "The App Store purchase could not be verified. Try restoring purchases."
        }
    }
}

@MainActor
protocol AccessProviding: AnyObject {
    var channel: DistributionChannel { get }

    func currentSnapshot(now: Date) async throws -> AccessSnapshot
    func startTrial(now: Date) async throws -> AccessSnapshot
    func purchase(now: Date) async throws -> AccessSnapshot
    func activate(licenseKey: String, now: Date) async throws -> AccessSnapshot
    func restore(now: Date) async throws -> AccessSnapshot
    func deactivate(now: Date) async throws -> AccessSnapshot
    func revalidateIfNeeded(now: Date) async throws -> AccessSnapshot?
    func observeChanges(_ handler: @escaping @MainActor () -> Void)
}

extension AccessProviding {
    func revalidateIfNeeded(now: Date) async throws -> AccessSnapshot? { nil }
    func observeChanges(_ handler: @escaping @MainActor () -> Void) {}
}

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
    var purchasedAt: Date?
}

enum AccessActionError: LocalizedError, Equatable {
    case configuration(String)
    case clockInvalid
    case unverifiedPurchase
    case appPurchaseRevoked
    case service(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .service(let message):
            message
        case .clockInvalid:
            "Flicksy could not verify the trial because the system clock moved backwards. Turn on automatic date and time, then try again."
        case .unverifiedPurchase:
            "The paid App Store download could not be verified. Connect to the internet and choose Verify Purchase."
        case .appPurchaseRevoked:
            "Apple reports that this app purchase was revoked. Download Flicksy from the purchasing Apple Account or contact Apple Support."
        }
    }
}

@MainActor
protocol AccessProviding: AnyObject {
    var channel: DistributionChannel { get }

    func currentSnapshot(now: Date) async throws -> AccessSnapshot
    func startTrial(now: Date) async throws -> AccessSnapshot
    func purchase(now: Date) async throws -> AccessSnapshot
    func restore(now: Date) async throws -> AccessSnapshot
    func observeChanges(_ handler: @escaping @MainActor () -> Void)
}

extension AccessProviding {
    func observeChanges(_ handler: @escaping @MainActor () -> Void) {}
}

//
//  AccessController.swift
//  Flicksy
//

import Foundation
import Observation

@Observable
@MainActor
final class AccessController {
    private(set) var state: AccessState = .loading
    private(set) var purchasePrice: String?
    private(set) var purchasedAt: Date?
    private(set) var activationUsage: Int?
    private(set) var activationLimit: Int?
    private(set) var isBusy = false
    var errorMessage: String?

    let channel: DistributionChannel

    private let provider: AccessProviding
    private let now: () -> Date
    private var hasStarted = false

    convenience init() {
#if APP_STORE_DISTRIBUTION
        self.init(provider: AppStoreAccessProvider())
#else
        self.init(provider: DirectAccessProvider())
#endif
    }

    init(provider: AccessProviding, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.channel = provider.channel
        self.now = now
        provider.observeChanges { [weak self] in
            Task { await self?.refresh(showErrors: false) }
        }
    }

    var hasAccess: Bool { state.allowsAccess }
    var isTrial: Bool {
        if case .trialActive = state { return true }
        return false
    }

    var trialExpiresAt: Date? {
        if case .trialActive(let expiresAt) = state { return expiresAt }
        return nil
    }

    var shouldShowTrialReminder: Bool {
        guard let trialExpiresAt else { return false }
        return trialExpiresAt.timeIntervalSince(now()) <= 3 * 24 * 60 * 60
    }

    var trialTimeRemaining: String? {
        guard let trialExpiresAt else { return nil }
        let remaining = max(0, trialExpiresAt.timeIntervalSince(now()))
        if remaining < 24 * 60 * 60 {
            let hours = max(1, Int(ceil(remaining / 3600)))
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        let days = Int(ceil(remaining / (24 * 60 * 60)))
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refresh(showErrors: true)
    }

    func refresh(showErrors: Bool = false) async {
        do {
            let snapshot = try await provider.currentSnapshot(now: now())
            apply(snapshot)
        } catch {
            if state == .loading {
                state = .recoverableError(message: error.localizedDescription, allowsAccess: false)
            } else if showErrors {
                errorMessage = error.localizedDescription
            }
            return
        }

        do {
            if let refreshed = try await provider.revalidateIfNeeded(now: now()) {
                apply(refreshed)
            }
        } catch {
            // A cached direct license remains usable indefinitely when the
            // license API or network is unavailable. Surface errors only when access is gated.
            if showErrors, !hasAccess {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startTrial() async {
        await perform { try await provider.startTrial(now: now()) }
    }

    func purchase() async {
        await perform { try await provider.purchase(now: now()) }
    }

    func activate(licenseKey: String) async -> Bool {
        var succeeded = false
        await perform {
            let snapshot = try await provider.activate(licenseKey: licenseKey, now: now())
            succeeded = snapshot.state == .licensed
            return snapshot
        }
        return succeeded
    }

    func restore() async {
        await perform { try await provider.restore(now: now()) }
    }

    func deactivate() async {
        await perform { try await provider.deactivate(now: now()) }
    }

    private func perform(_ operation: () async throws -> AccessSnapshot) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            apply(try await operation())
        } catch AccessActionError.purchaseCancelled {
            // Cancellation is an expected outcome and does not need an alert.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ snapshot: AccessSnapshot) {
        state = snapshot.state
        purchasePrice = snapshot.purchasePrice
        purchasedAt = snapshot.purchasedAt
        activationUsage = snapshot.activationUsage
        activationLimit = snapshot.activationLimit
    }
}

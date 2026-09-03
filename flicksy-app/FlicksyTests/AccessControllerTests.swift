import XCTest
@testable import Flicksy

@MainActor
final class AccessControllerTests: XCTestCase {
    func testLicensedAndActiveTrialAllowAccess() {
        XCTAssertTrue(AccessState.licensed.allowsAccess)
        XCTAssertTrue(AccessState.trialActive(expiresAt: .distantFuture).allowsAccess)
        XCTAssertFalse(AccessState.trialAvailable.allowsAccess)
        XCTAssertFalse(AccessState.expired.allowsAccess)
    }

    func testControllerAppliesProviderSnapshot() async {
        let provider = StubAccessProvider(
            snapshot: AccessSnapshot(
                state: .licensed,
                purchasePrice: "$19",
                purchasedAt: Date(timeIntervalSince1970: 100)
            )
        )
        let controller = AccessController(provider: provider)

        await controller.start()

        XCTAssertEqual(controller.state, .licensed)
        XCTAssertEqual(controller.purchasePrice, "$19")
        XCTAssertTrue(controller.hasAccess)
    }

    func testRecoverableProviderFailureDoesNotGrantAccess() async {
        let provider = StubAccessProvider(
            snapshot: AccessSnapshot(state: .trialAvailable),
            error: AccessActionError.service("Unavailable")
        )
        let controller = AccessController(provider: provider)

        await controller.start()

        XCTAssertEqual(
            controller.state,
            .recoverableError(message: "Unavailable", allowsAccess: false)
        )
        XCTAssertFalse(controller.hasAccess)
    }
}

@MainActor
private final class StubAccessProvider: AccessProviding {
    let channel = DistributionChannel.direct
    let snapshot: AccessSnapshot
    let error: Error?

    init(snapshot: AccessSnapshot, error: Error? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    func currentSnapshot(now: Date) async throws -> AccessSnapshot {
        if let error { throw error }
        return snapshot
    }

    func startTrial(now: Date) async throws -> AccessSnapshot { snapshot }
    func purchase(now: Date) async throws -> AccessSnapshot { snapshot }
    func activate(licenseKey: String, now: Date) async throws -> AccessSnapshot { snapshot }
    func restore(now: Date) async throws -> AccessSnapshot { snapshot }
    func deactivate(now: Date) async throws -> AccessSnapshot { snapshot }
}

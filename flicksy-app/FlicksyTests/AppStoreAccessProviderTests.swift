#if APP_STORE_DISTRIBUTION
import XCTest
@testable import Flicksy

@MainActor
final class AppStoreAccessProviderTests: XCTestCase {
    private let configuration = AppStoreAccessConfiguration(
        bundleID: "cloudedminds.Flicksy",
        appID: 123_456_789
    )
    private let purchaseDate = Date(timeIntervalSince1970: 2_000_000)

    func testVerifiedPaidDownloadGrantsAccessAndCachesForOfflineLaunches() async throws {
        let store = MemorySecureStore()
        let purchase = matchingPurchase()
        let online = AppStoreAccessProvider(
            configuration: configuration,
            verifier: FakeAppPurchaseVerifier(current: .value(.verified(purchase))),
            secureStore: store
        )

        let verified = try await online.currentSnapshot(now: purchaseDate)
        XCTAssertEqual(verified.state, .licensed)
        XCTAssertEqual(verified.purchasedAt, purchaseDate)

        let offline = AppStoreAccessProvider(
            configuration: configuration,
            verifier: FakeAppPurchaseVerifier(current: .failure),
            secureStore: store
        )
        let cached = try await offline.currentSnapshot(now: purchaseDate)
        XCTAssertEqual(cached.state, .licensed)
        XCTAssertEqual(cached.purchasedAt, purchaseDate)
    }

    func testUnverifiedTransactionDoesNotUseCachedAccess() async throws {
        let store = MemorySecureStore()
        let verified = AppStoreAccessProvider(
            configuration: configuration,
            verifier: FakeAppPurchaseVerifier(current: .value(.verified(matchingPurchase()))),
            secureStore: store
        )
        _ = try await verified.currentSnapshot(now: purchaseDate)

        let unverified = AppStoreAccessProvider(
            configuration: configuration,
            verifier: FakeAppPurchaseVerifier(current: .value(.unverified)),
            secureStore: store
        )
        await XCTAssertThrowsErrorAsync(try await unverified.currentSnapshot(now: purchaseDate)) { error in
            XCTAssertEqual(error as? AccessActionError, .unverifiedPurchase)
        }
    }

    func testWrongAppIdentityIsRejected() async {
        let wrongApp = VerifiedAppPurchase(
            bundleID: "example.OtherApp",
            appID: configuration.appID,
            appTransactionID: "app-transaction-123",
            originalPurchaseDate: purchaseDate,
            revocationDate: nil
        )
        let provider = AppStoreAccessProvider(
            configuration: configuration,
            verifier: FakeAppPurchaseVerifier(current: .value(.verified(wrongApp))),
            secureStore: MemorySecureStore()
        )

        await XCTAssertThrowsErrorAsync(try await provider.currentSnapshot(now: purchaseDate)) { error in
            XCTAssertEqual(error as? AccessActionError, .unverifiedPurchase)
        }
    }

    func testRevokedPaidDownloadIsRejectedAndNotCached() async {
        let revoked = VerifiedAppPurchase(
            bundleID: configuration.bundleID,
            appID: configuration.appID,
            appTransactionID: "app-transaction-123",
            originalPurchaseDate: purchaseDate,
            revocationDate: purchaseDate.addingTimeInterval(100)
        )
        let provider = AppStoreAccessProvider(
            configuration: configuration,
            verifier: FakeAppPurchaseVerifier(current: .value(.verified(revoked))),
            secureStore: MemorySecureStore()
        )

        await XCTAssertThrowsErrorAsync(try await provider.currentSnapshot(now: purchaseDate)) { error in
            XCTAssertEqual(error as? AccessActionError, .appPurchaseRevoked)
        }
    }

    func testUserTriggeredVerificationUsesRefresh() async throws {
        let provider = AppStoreAccessProvider(
            configuration: configuration,
            verifier: FakeAppPurchaseVerifier(
                current: .value(.unverified),
                refresh: .value(.verified(matchingPurchase()))
            ),
            secureStore: MemorySecureStore()
        )

        let refreshed = try await provider.restore(now: purchaseDate)
        XCTAssertEqual(refreshed.state, .licensed)
    }

    func testAppStoreBuildHasNoTrialOrInAppPurchase() async {
        let provider = AppStoreAccessProvider(
            configuration: configuration,
            verifier: FakeAppPurchaseVerifier(current: .value(.verified(matchingPurchase()))),
            secureStore: MemorySecureStore()
        )

        await XCTAssertThrowsErrorAsync(try await provider.startTrial(now: purchaseDate)) { error in
            XCTAssertEqual(
                error as? AccessActionError,
                .configuration("The paid Mac App Store version does not include a trial.")
            )
        }
        await XCTAssertThrowsErrorAsync(try await provider.purchase(now: purchaseDate)) { error in
            XCTAssertEqual(
                error as? AccessActionError,
                .configuration("Flicksy is purchased upfront from the Mac App Store.")
            )
        }
    }

    private func matchingPurchase() -> VerifiedAppPurchase {
        VerifiedAppPurchase(
            bundleID: configuration.bundleID,
            appID: configuration.appID,
            appTransactionID: "app-transaction-123",
            originalPurchaseDate: purchaseDate,
            revocationDate: nil
        )
    }
}

private enum FakeAppPurchaseOutcome: Sendable {
    case value(AppPurchaseVerification)
    case failure
}

private struct FakeAppPurchaseVerifier: AppPurchaseVerifying {
    let currentOutcome: FakeAppPurchaseOutcome
    let refreshOutcome: FakeAppPurchaseOutcome

    init(
        current: FakeAppPurchaseOutcome,
        refresh: FakeAppPurchaseOutcome? = nil
    ) {
        currentOutcome = current
        refreshOutcome = refresh ?? current
    }

    func current() async throws -> AppPurchaseVerification { try resolve(currentOutcome) }
    func refresh() async throws -> AppPurchaseVerification { try resolve(refreshOutcome) }

    private func resolve(_ outcome: FakeAppPurchaseOutcome) throws -> AppPurchaseVerification {
        switch outcome {
        case .value(let result): result
        case .failure: throw URLError(.notConnectedToInternet)
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
#endif

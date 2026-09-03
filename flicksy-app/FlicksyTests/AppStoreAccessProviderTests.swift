#if APP_STORE_DISTRIBUTION
import StoreKitTest
import XCTest
@testable import Flicksy

@MainActor
final class AppStoreAccessProviderTests: XCTestCase {
    private var session: SKTestSession!

    override func setUpWithError() throws {
        session = try SKTestSession(configurationFileNamed: "Flicksy")
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDownWithError() throws {
        session.clearTransactions()
        session = nil
    }

    func testFreshAccountCanStartTrial() async throws {
        let provider = AppStoreAccessProvider()
        let now = Date()

        let initial = try await provider.currentSnapshot(now: now)
        XCTAssertEqual(initial.state, .trialAvailable)
        let snapshot = try await provider.startTrial(now: now)
        guard case .trialActive(let expiresAt) = snapshot.state else {
            return XCTFail("Expected active StoreKit trial")
        }
        XCTAssertEqual(expiresAt.timeIntervalSince(now), AppStoreAccessProvider.trialDuration, accuracy: 5)
    }

    func testExpiredTrialDoesNotGrantAccess() async throws {
        let provider = AppStoreAccessProvider()
        _ = try await provider.startTrial(now: Date())

        let snapshot = try await provider.currentSnapshot(
            now: Date().addingTimeInterval(AppStoreAccessProvider.trialDuration + 60)
        )

        XCTAssertEqual(snapshot.state, .expired)
    }

    func testLifetimePurchaseOverridesExpiredTrial() async throws {
        let provider = AppStoreAccessProvider()
        _ = try await provider.startTrial(now: Date())

        let snapshot = try await provider.purchase(now: Date())

        XCTAssertEqual(snapshot.state, .licensed)
        XCTAssertNotNil(snapshot.purchasedAt)
    }

}
#endif

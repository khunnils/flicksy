#if DIRECT_DISTRIBUTION
import XCTest
@testable import Flicksy

@MainActor
final class DirectAccessProviderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000)

    func testTrialDoesNotStartUntilExplicitlyRequested() async throws {
        let provider = makeProvider()
        let before = try await provider.currentSnapshot(now: start)
        XCTAssertEqual(before.state, .trialAvailable)
        let started = try await provider.startTrial(now: start)
        XCTAssertEqual(
            started.state,
            .trialActive(expiresAt: start.addingTimeInterval(DirectAccessProvider.trialDuration))
        )
    }

    func testTrialExpiresAtExactFourteenDayBoundaryAndPersists() async throws {
        let store = MemorySecureStore()
        _ = try await makeProvider(store: store).startTrial(now: start)
        let provider = makeProvider(store: store)
        let justBefore = try await provider.currentSnapshot(now: start.addingTimeInterval(DirectAccessProvider.trialDuration - 1))
        let atBoundary = try await provider.currentSnapshot(now: start.addingTimeInterval(DirectAccessProvider.trialDuration))
        XCTAssertTrue(justBefore.state.allowsAccess)
        XCTAssertEqual(atBoundary.state, .expired)
    }

    func testClockRollbackBlocksTrialUntilClockIsCorrected() async throws {
        let provider = makeProvider()
        _ = try await provider.startTrial(now: start)
        _ = try await provider.currentSnapshot(now: start.addingTimeInterval(20 * 60))
        let rolledBack = try await provider.currentSnapshot(now: start)
        XCTAssertEqual(
            rolledBack.state,
            .recoverableError(message: AccessActionError.clockInvalid.localizedDescription, allowsAccess: false)
        )
    }

    func testPurchaseOpensConfiguredAppStoreListingWithoutChangingTrial() async throws {
        var openedURL: URL?
        let provider = DirectAccessProvider(
            configuration: DirectAccessConfiguration(appStoreURL: URL(string: "https://apps.apple.com/app/id1234567890")),
            secureStore: MemorySecureStore(),
            openURL: { openedURL = $0; return true }
        )
        let snapshot = try await provider.purchase(now: start)
        XCTAssertEqual(snapshot.state, .trialAvailable)
        XCTAssertEqual(openedURL?.absoluteString, "https://apps.apple.com/app/id1234567890")
    }

    func testPurchaseExplainsWhenAppStoreListingIsUnavailable() async throws {
        let provider = makeProvider()
        do {
            _ = try await provider.purchase(now: start)
            XCTFail("Expected an unavailable-listing error")
        } catch let error as AccessActionError {
            XCTAssertEqual(error, .configuration("Flicksy is not available on the App Store yet. Please check back soon."))
        }
    }

    private func makeProvider(store: SecureStoring = MemorySecureStore()) -> DirectAccessProvider {
        DirectAccessProvider(configuration: DirectAccessConfiguration(appStoreURL: nil), secureStore: store)
    }
}
#endif

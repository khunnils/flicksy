#if DIRECT_DISTRIBUTION
import Foundation
import XCTest
@testable import Flicksy

@MainActor
final class DirectAccessProviderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000)

    override func tearDown() {
        LicenseURLProtocol.handler = nil
        super.tearDown()
    }

    func testTrialDoesNotStartUntilExplicitlyRequested() async throws {
        let store = MemorySecureStore()
        let provider = makeProvider(store: store)

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
        let firstProvider = makeProvider(store: store)
        _ = try await firstProvider.startTrial(now: start)

        let secondProvider = makeProvider(store: store)
        let justBefore = try await secondProvider.currentSnapshot(
            now: start.addingTimeInterval(DirectAccessProvider.trialDuration - 1)
        )
        XCTAssertTrue(justBefore.state.allowsAccess)

        let atBoundary = try await secondProvider.currentSnapshot(
            now: start.addingTimeInterval(DirectAccessProvider.trialDuration)
        )
        XCTAssertEqual(atBoundary.state, .expired)
    }

    func testClockRollbackBlocksTrialUntilClockIsCorrected() async throws {
        let store = MemorySecureStore()
        let provider = makeProvider(store: store)
        _ = try await provider.startTrial(now: start)
        _ = try await provider.currentSnapshot(now: start.addingTimeInterval(20 * 60))

        let rolledBack = try await provider.currentSnapshot(now: start)
        XCTAssertEqual(
            rolledBack.state,
            .recoverableError(
                message: AccessActionError.clockInvalid.localizedDescription,
                allowsAccess: false
            )
        )
    }

    func testActivationPersistsOfflineLicense() async throws {
        LicenseURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.lastPathComponent, "activate")
            return Self.response(json: Self.activationJSON)
        }
        let store = MemorySecureStore()
        let provider = makeProvider(store: store)

        let activated = try await provider.activate(
            licenseKey: "  12345678-1234-1234-1234-123456789012  ",
            now: start
        )
        XCTAssertEqual(activated.state, .licensed)
        XCTAssertEqual(activated.activationUsage, 1)
        XCTAssertEqual(activated.activationLimit, 3)

        LicenseURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let relaunched = try await makeProvider(store: store).currentSnapshot(now: start.addingTimeInterval(100))
        XCTAssertEqual(relaunched.state, .licensed)
    }

    func testActivationRejectsLicenseForAnotherProduct() async throws {
        LicenseURLProtocol.handler = { _ in
            Self.response(
                json: """
                {"ok":false,"error":"This key is not a Flicksy license.","error_code":"invalid"}
                """,
                status: 404
            )
        }

        do {
            _ = try await makeProvider().activate(licenseKey: "12345678-1234-1234", now: start)
            XCTFail("Expected the product mismatch to be rejected")
        } catch let error as AccessActionError {
            XCTAssertEqual(error, .invalidLicense("This key is not a Flicksy license."))
        }
    }

    func testActivationLimitErrorIsPresentedClearly() async throws {
        LicenseURLProtocol.handler = { _ in
            Self.response(
                json: """
                {"ok":false,"error":"This license key has reached the activation limit.","error_code":"limit"}
                """,
                status: 403
            )
        }

        do {
            _ = try await makeProvider().activate(licenseKey: "12345678-1234-1234", now: start)
            XCTFail("Expected activation limit error")
        } catch let error as AccessActionError {
            XCTAssertEqual(error, .activationLimitReached)
        }
    }

    func testMalformedLicenseKeyIsRejectedBeforeNetworkAccess() async throws {
        LicenseURLProtocol.handler = { _ in
            XCTFail("Malformed keys must not reach the licensing service")
            throw URLError(.badURL)
        }

        do {
            _ = try await makeProvider().activate(licenseKey: "too-short", now: start)
            XCTFail("Expected malformed license key error")
        } catch let error as AccessActionError {
            XCTAssertEqual(error, .invalidLicense("Enter the complete license key from your Flicksy receipt."))
        }
    }

    func testExplicitInvalidRevalidationRemovesCachedLicense() async throws {
        var isActivation = true
        LicenseURLProtocol.handler = { request in
            if isActivation {
                isActivation = false
                return Self.response(json: Self.activationJSON)
            }
            XCTAssertEqual(request.url?.lastPathComponent, "validate")
            return Self.response(
                json: """
                {"ok":false,"status":"disabled","error":"The license key has been disabled.","error_code":"invalid"}
                """,
                status: 410
            )
        }
        let store = MemorySecureStore()
        let provider = makeProvider(store: store)
        _ = try await provider.activate(licenseKey: "12345678-1234-1234", now: start)

        let refreshed = try await provider.revalidateIfNeeded(
            now: start.addingTimeInterval(DirectAccessProvider.validationInterval + 1)
        )
        XCTAssertEqual(refreshed?.state, .trialAvailable)
        let current = try await provider.currentSnapshot(now: start)
        XCTAssertEqual(current.state, .trialAvailable)
    }

    func testRevalidationForAnotherProductRemovesCachedLicense() async throws {
        var isActivation = true
        LicenseURLProtocol.handler = { _ in
            if isActivation {
                isActivation = false
                return Self.response(json: Self.activationJSON)
            }
            return Self.response(
                json: """
                {"ok":false,"error":"This key is not a Flicksy license.","error_code":"invalid"}
                """,
                status: 404
            )
        }
        let store = MemorySecureStore()
        let provider = makeProvider(store: store)
        _ = try await provider.activate(licenseKey: "12345678-1234-1234", now: start)

        let refreshed = try await provider.revalidateIfNeeded(
            now: start.addingTimeInterval(DirectAccessProvider.validationInterval + 1)
        )

        XCTAssertEqual(refreshed?.state, .trialAvailable)
        let current = try await provider.currentSnapshot(now: start)
        XCTAssertEqual(current.state, .trialAvailable)
    }

    func testOfflineWeeklyValidationKeepsCachedLicense() async throws {
        var isActivation = true
        LicenseURLProtocol.handler = { _ in
            if isActivation {
                isActivation = false
                return Self.response(json: Self.activationJSON)
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = MemorySecureStore()
        let provider = makeProvider(store: store)
        _ = try await provider.activate(licenseKey: "12345678-1234-1234", now: start)

        do {
            _ = try await provider.revalidateIfNeeded(
                now: start.addingTimeInterval(DirectAccessProvider.validationInterval + 1)
            )
            XCTFail("Expected the simulated network failure")
        } catch {
            // The validation attempt fails, but cached access remains intact.
        }

        let current = try await provider.currentSnapshot(
            now: start.addingTimeInterval(DirectAccessProvider.validationInterval + 1)
        )
        XCTAssertEqual(current.state, .licensed)
    }

    func testDeactivationReturnsSeatBeforeClearingLocalLicense() async throws {
        var isActivation = true
        LicenseURLProtocol.handler = { request in
            if isActivation {
                isActivation = false
                return Self.response(json: Self.activationJSON)
            }
            XCTAssertEqual(request.url?.lastPathComponent, "deactivate")
            return Self.response(json: """
            {"ok":true,"status":"active","activation_usage":0,"activation_limit":3}
            """)
        }
        let provider = makeProvider()
        _ = try await provider.activate(licenseKey: "12345678-1234-1234", now: start)

        let result = try await provider.deactivate(now: start)

        XCTAssertEqual(result.state, .trialAvailable)
    }

    func testConfiguredLicenseURLMustBeTheBaseAndAppendsActionOnce() async throws {
        LicenseURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://flicksy.me/api/licenses/activate")
            return Self.response(json: Self.activationJSON)
        }
        let provider = makeProvider()

        _ = try await provider.activate(licenseKey: "12345678-1234-1234", now: start)
    }

    private func makeProvider(store suppliedStore: SecureStoring? = nil) -> DirectAccessProvider {
        let store = suppliedStore ?? MemorySecureStore()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LicenseURLProtocol.self]
        return DirectAccessProvider(
            configuration: DirectAccessConfiguration(
                checkoutURL: URL(string: "https://example.com/buy"),
                licenseAPIURL: URL(string: "https://flicksy.me/api/licenses"),
                purchasePrice: "$19"
            ),
            secureStore: store,
            session: URLSession(configuration: sessionConfiguration),
            openURL: { _ in true }
        )
    }

    private static func response(json: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        let url = URL(string: "https://flicksy.me/api/licenses")!
        return (
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(json.utf8)
        )
    }

    private static let activationJSON = """
    {
      "ok": true,
      "status": "active",
      "instance_id": "instance-123",
      "created_at": "2026-08-01T10:00:00.000000Z",
      "activation_usage": 1,
      "activation_limit": 3
    }
    """
}

private final class LicenseURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
#endif

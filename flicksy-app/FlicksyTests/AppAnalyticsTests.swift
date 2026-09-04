import XCTest
@testable import Flicksy

@MainActor
final class AppAnalyticsTests: XCTestCase {
    func testConsentGatesInitializationAndEventsAndPersists() {
        let suite = "AnalyticsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var starts = 0
        var stops = 0
        var events: [String] = []
        let analytics = AppAnalytics(defaults: defaults, appID: UUID().uuidString,
            initialize: { _ in starts += 1 }, send: { events.append($0) }, stop: { stops += 1 })
        analytics.start()
        analytics.record(.previewOpened)
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(events.isEmpty)
        analytics.setEnabled(true)
        analytics.start()
        analytics.record(.previewOpened)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(events, ["com.flicksy.App.launched", "com.flicksy.Preview.opened"])
        XCTAssertTrue(defaults.bool(forKey: AppAnalytics.enabledKey))
        analytics.setEnabled(false)
        analytics.record(.comparisonOpened)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(events.count, 2)
        XCTAssertFalse(defaults.bool(forKey: AppAnalytics.enabledKey))
    }

    func testMissingOrInvalidIDNeverInitializes() {
        let suite = "AnalyticsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for id in [nil, "", "$(FLICKSY_TELEMETRYDECK_APP_ID)", "not-an-id"] as [String?] {
            let analytics = AppAnalytics(defaults: defaults, appID: id,
                initialize: { _ in XCTFail("Invalid ID must not initialize") },
                send: { _ in XCTFail("Invalid ID must not send") }, stop: {})
            analytics.setEnabled(true)
            analytics.record(.previewOpened)
        }
    }
}

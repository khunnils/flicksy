import Foundation
import TelemetryDeck

/// Only fixed event names cross this boundary. Never add free-form parameters,
/// URLs, errors, media metadata, license keys, or user identifiers here.
@MainActor
final class AppAnalytics {
    enum Event: String, CaseIterable {
        case launched = "com.flicksy.App.launched"
        case previewOpened = "com.flicksy.Preview.opened"
        case comparisonOpened = "com.flicksy.Comparison.opened"
        case commandPaletteOpened = "com.flicksy.CommandPalette.opened"
    }

    static let enabledKey = "shareAnonymousUsage"
    static let shared = AppAnalytics(appID:
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? Bundle.main.object(forInfoDictionaryKey: "FlicksyTelemetryDeckAppID") as? String : nil
    )
    private let defaults: UserDefaults
    private let appID: String?
    private let initialize: @MainActor (String) -> Void
    private let send: @MainActor (String) -> Void
    private let stop: @MainActor () -> Void
    private var running = false

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    init(
        defaults: UserDefaults = .standard,
        appID: String? = Bundle.main.object(forInfoDictionaryKey: "FlicksyTelemetryDeckAppID") as? String,
        initialize: @escaping @MainActor (String) -> Void = { TelemetryBackend.start(appID: $0) },
        send: @escaping @MainActor (String) -> Void = { TelemetryDeck.signal($0) },
        stop: @escaping @MainActor () -> Void = { TelemetryBackend.stop() }
    ) {
        self.defaults = defaults
        self.appID = appID
        self.initialize = initialize
        self.send = send
        self.stop = stop
    }

    func start() {
        guard !running, isEnabled, let appID, UUID(uuidString: appID) != nil else { return }
        initialize(appID)
        running = true
        record(.launched)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else if running {
            running = false
            stop()
        }
    }

    func record(_ event: Event) {
        guard running, isEnabled else { return }
        send(event.rawValue)
    }
}

@MainActor
private enum TelemetryBackend {
    private static var config: TelemetryDeck.Config?
    private static var session: URLSession?

    static func start(appID: String) {
        let config = TelemetryDeck.Config(appID: appID)
        // Explicit events only; no lifecycle/session-duration automation.
        config.sendNewSessionBeganSignal = false
        config.sessionStatsEnabled = false
        config.logHandler = nil
#if DEBUG || TEST_ENVIRONMENT
        config.testMode = true
#else
        config.testMode = false
#endif
        let session = URLSession(configuration: .ephemeral)
        config.urlSession = session
        self.config = config
        self.session = session
        TelemetryDeck.initialize(config: config)
    }

    static func stop() {
        config?.analyticsDisabled = true
        // The SDK flag gates new signals, but not previously queued requests.
        session?.invalidateAndCancel()
        TelemetryDeck.terminate()
        session = nil
        config = nil
    }
}

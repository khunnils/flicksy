//
//  UpdateController.swift
//  Flicksy
//

import Foundation
import Observation

#if DIRECT_DISTRIBUTION
import Sparkle

private final class FlicksyUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}

@Observable
@MainActor
final class UpdateController {
    private let controller: SPUStandardUpdaterController
    private let updaterDelegate: FlicksyUpdaterDelegate
    let isConfigured: Bool

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isConfigured = URL(string: feed)?.scheme == "https" && !publicKey.isEmpty
        updaterDelegate = FlicksyUpdaterDelegate()
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        if isConfigured {
            try? controller.updater.start()
        }
    }

    var canCheckForUpdates: Bool {
        isConfigured && controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }
}
#else
@Observable
@MainActor
final class UpdateController {
    let isConfigured = false
    let canCheckForUpdates = false
    func checkForUpdates() {}
}
#endif

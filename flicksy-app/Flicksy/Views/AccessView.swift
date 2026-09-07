//
//  AccessView.swift
//  Flicksy
//

import SwiftUI

struct FlicksyRootView: View {
    @Environment(AccessController.self) private var access
    @State private var browserModel: BrowserModel?

    init() {}

    var body: some View {
        Group {
            if access.state == .loading {
                ProgressView("Checking Flicksy access…")
                    .frame(minWidth: 540, minHeight: 420)
            } else if access.hasAccess {
                if let browserModel {
                    MainView()
                        .environment(browserModel)
                        .safeAreaInset(edge: .top, spacing: 0) {
#if DIRECT_DISTRIBUTION
                            if access.shouldShowTrialReminder {
                                TrialReminderView()
                                    .environment(access)
                            }
#endif
                        }
                } else {
                    ProgressView("Opening Flicksy…")
                        .frame(minWidth: 540, minHeight: 420)
                        .task {
                            guard access.hasAccess, browserModel == nil else { return }
                            browserModel = BrowserModel()
                        }
                }
            } else {
                AccessGateView()
            }
        }
        .task {
            await access.start()
        }
        .task(id: access.trialExpiresAt) {
            while !Task.isCancelled, access.isTrial {
                let untilExpiration = access.trialExpiresAt?.timeIntervalSinceNow ?? 60
                let delay = max(0.1, min(60, untilExpiration))
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await access.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await access.refresh() }
        }
        .onChange(of: access.hasAccess) { _, hasAccess in
            if !hasAccess {
                browserModel = nil
            }
        }
        .alert(
            "Flicksy Access",
            isPresented: Binding(
                get: { access.errorMessage != nil },
                set: { if !$0 { access.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { access.errorMessage = nil }
        } message: {
            Text(access.errorMessage ?? "")
        }
    }
}

struct AccessGateView: View {
    @Environment(AccessController.self) private var access

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 104, height: 104)
                .accessibilityLabel("Flicksy app icon")

            Text(title)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .tracking(-0.6)
                .padding(.top, 16)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 440)
                .padding(.top, 9)

#if DIRECT_DISTRIBUTION
            directControls
                .padding(.top, 25)
#else
            appStoreControls
                .padding(.top, 25)
#endif

            Text(footer)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 18)

            Spacer(minLength: 30)
        }
        .padding(.horizontal, 36)
        .frame(minWidth: 600, idealWidth: 680, minHeight: 520, idealHeight: 590)
        .background(Color(nsColor: .windowBackgroundColor))
    }

#if DIRECT_DISTRIBUTION
    private var directControls: some View {
        VStack(spacing: 12) {
            if canStartTrial {
                Button("Start 14-Day Free Trial") {
                    Task { await access.startTrial() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Button("Buy on the App Store") {
                Task { await access.purchase() }
            }
            .controlSize(.large)

            if access.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .disabled(access.isBusy)
    }
#else

    private var appStoreControls: some View {
        VStack(spacing: 12) {
            Button("Verify App Store Purchase") {
                Task { await access.restore() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if access.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .disabled(access.isBusy)
    }
#endif

    private var canStartTrial: Bool {
        if case .trialAvailable = access.state { return true }
        return false
    }

    private var title: String {
#if APP_STORE_DISTRIBUTION
        return "Verify your paid download"
#else
        return switch access.state {
        case .expired:
            "Your trial has ended"
        case .recoverableError:
            "Flicksy needs your attention"
        default:
            "Try everything for 14 days"
        }
#endif
    }

    private var message: String {
#if APP_STORE_DISTRIBUTION
        if case .recoverableError(let message, _) = access.state { return message }
        return "Flicksy verifies the App Store-signed purchase included with this download. No trial or in-app purchase is required."
#else
        return switch access.state {
        case .expired:
            "Buy and install Flicksy from the Mac App Store to continue. Your folders and Flicksy library remain untouched."
        case .recoverableError(let message, _):
            message
        default:
            "The complete app is included. The trial starts only when you choose, does not renew, and never charges you automatically."
        }
#endif
    }

    private var footer: String {
#if DIRECT_DISTRIBUTION
        "No Flicksy account required. Buy and install the Mac App Store version to continue after your trial."
#else
        "No Flicksy account required. The paid download is associated with your Apple Account."
#endif
    }

}

#if DIRECT_DISTRIBUTION
struct TrialReminderView: View {
    @Environment(AccessController.self) private var access

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            Text("Your Flicksy trial has \(access.trialTimeRemaining ?? "a little time") remaining.")
                .font(.callout)
            Spacer()
            Button("View on App Store") {
                Task { await access.purchase() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}
#endif

struct LicenseView: View {
    static let windowID = "flicksy-license"

    @Environment(AccessController.self) private var access
    var body: some View {
        content
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Flicksy Access")
                        .font(.title2.weight(.semibold))
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if let expiresAt = access.trialExpiresAt {
                LabeledContent("Trial ends", value: expiresAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let purchasedAt = access.purchasedAt {
                LabeledContent("Purchased", value: purchasedAt.formatted(date: .abbreviated, time: .omitted))
            }
#if APP_STORE_DISTRIBUTION
            LabeledContent("Purchase channel", value: "Mac App Store")
#endif

#if TEST_ENVIRONMENT
            HStack {
                Button("Reset Trial") { Task { await access.resetTrialForTesting() } }
                Button("Expire Trial") { Task { await access.expireTrialForTesting() } }
            }
            .help("Flicksy Test only — production builds do not contain these controls.")
#endif

            controls
        }
        .padding(24)
        .frame(width: 440)
        .background(.background)
    }

    @ViewBuilder
    private var controls: some View {
#if DIRECT_DISTRIBUTION
        Button("View on App Store") { Task { await access.purchase() } }
#else
        HStack {
            if access.state != .licensed {
                Button("Verify App Store Purchase") { Task { await access.restore() } }
                .buttonStyle(.borderedProminent)
            } else {
                Label("Paid download verified", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
            }
        }
#endif
    }

    private var statusText: String {
        switch access.state {
        case .licensed:
            "Lifetime license — all future updates included"
        case .trialActive:
            "Free trial — \(access.trialTimeRemaining ?? "active") remaining"
        case .expired:
            "Trial expired"
        case .trialAvailable:
            "Trial not started"
        case .loading:
            "Checking access…"
        case .recoverableError(let message, _):
            message
        }
    }
}

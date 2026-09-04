//
//  AccessView.swift
//  Flicksy
//

import SwiftUI

struct FlicksyRootView: View {
    @Environment(AccessController.self) private var access
    @Binding var browserModel: BrowserModel?

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
#if DIRECT_DISTRIBUTION
    @State private var licenseKey = ""
#endif

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

            Button("Buy Flicksy — \(access.purchasePrice ?? "$19")") {
                Task { await access.purchase() }
            }
            .controlSize(.large)

            HStack(spacing: 8) {
                TextField("License key", text: $licenseKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 285)
                    .onSubmit { activate() }

                Button("Activate") { activate() }
                    .disabled(licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 4)

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
            "Buy Flicksy once to keep using the complete app and receive every future update. Your folders and Flicksy library remain untouched."
        case .recoverableError(let message, _):
            message
        default:
            "The complete app is included. The trial starts only when you choose, does not renew, and never charges you automatically."
        }
#endif
    }

    private var footer: String {
#if DIRECT_DISTRIBUTION
        "No Flicksy account required. Your license key arrives by email and works on up to three Macs."
#else
        "No Flicksy account required. The paid download is associated with your Apple Account."
#endif
    }

#if DIRECT_DISTRIBUTION
    private func activate() {
        let key = licenseKey
        Task {
            if await access.activate(licenseKey: key) {
                licenseKey = ""
            }
        }
    }
#endif
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
            Button("Buy Flicksy") {
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
#if DIRECT_DISTRIBUTION
    @State private var licenseKey = ""
    @State private var confirmsDeactivation = false
#endif

    var body: some View {
#if DIRECT_DISTRIBUTION
        content
            .confirmationDialog(
                "Deactivate Flicksy on this Mac?",
                isPresented: $confirmsDeactivation
            ) {
                Button("Deactivate This Mac", role: .destructive) {
                    Task { await access.deactivate() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This returns one activation to your license. An internet connection is required.")
            }
#else
        content
#endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Flicksy License")
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
#if DIRECT_DISTRIBUTION
            LabeledContent("Purchase channel", value: "Direct")
#else
            LabeledContent("Purchase channel", value: "Mac App Store")
#endif

#if DIRECT_DISTRIBUTION
            if let usage = access.activationUsage, let limit = access.activationLimit {
                LabeledContent("Activations", value: "\(usage) of \(limit)")
            }

#if TEST_ENVIRONMENT
            HStack {
                Button("Reset Trial") { Task { await access.resetTrialForTesting() } }
                Button("Expire Trial") { Task { await access.expireTrialForTesting() } }
            }
            .help("Flicksy Test only — production builds do not contain these controls.")
#endif
#endif

            controls

            Text("Direct and Mac App Store purchases are separate and cannot be restored across stores.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 440)
        .background(.background)
    }

    @ViewBuilder
    private var controls: some View {
#if DIRECT_DISTRIBUTION
        if access.state == .licensed {
            HStack {
                Button("Buy Another License") { Task { await access.purchase() } }
                Spacer()
                Button("Deactivate This Mac") { confirmsDeactivation = true }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("License key", text: $licenseKey)
                    Button("Activate") {
                        let key = licenseKey
                        Task {
                            if await access.activate(licenseKey: key) { licenseKey = "" }
                        }
                    }
                    .disabled(licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("Buy Flicksy — \(access.purchasePrice ?? "$19")") {
                    Task { await access.purchase() }
                }
            }
        }
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

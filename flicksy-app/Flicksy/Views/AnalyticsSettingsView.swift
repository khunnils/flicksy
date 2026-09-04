import SwiftUI

struct AnalyticsSettingsView: View {
    @State private var analyticsEnabled = AppAnalytics.shared.isEnabled

    var body: some View {
        Form {
            Section("Privacy") {
                Toggle("Share anonymous usage analytics", isOn: $analyticsEnabled)
                    .onChange(of: analyticsEnabled) { _, enabled in
                        AppAnalytics.shared.setEnabled(enabled)
                    }
                Text("Help improve Flicksy by sharing which features you use, along with basic app and device information through TelemetryDeck. Off by default. Filenames, paths, media, tags, search text, and license details are never included.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("Privacy policy", destination: URL(string: "https://flicksy.me/privacy")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 230)
    }
}

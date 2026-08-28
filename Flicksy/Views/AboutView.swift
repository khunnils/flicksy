//
//  AboutView.swift
//  Flicksy
//

import AppKit
import SwiftUI

/// Branded, native About window opened from Flicksy's application menu.
struct AboutView: View {
    static let windowID = "about-flicksy"

    private let version = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "—"

    private let build = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "—"

    private let copyright = Bundle.main.object(
        forInfoDictionaryKey: "NSHumanReadableCopyright"
    ) as? String ?? "© 2026 Flicksy"

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .accessibilityLabel("Flicksy app icon")
                .padding(.bottom, 14)

            Text("Flicksy")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .tracking(-0.7)

            Text("A fast, minimal media browser for Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 5)

            Text("Version \(version) (\(build))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.top, 14)

            Divider()
                .padding(.vertical, 18)

            Text("Browse images, video, and audio with native previews, fast scrubbing, and no library to manage.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 310)

            Text(copyright)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
        }
        .padding(.horizontal, 34)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: 390)
        .background(.background)
    }
}

#Preview {
    AboutView()
}

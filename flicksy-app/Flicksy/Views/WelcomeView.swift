//
//  WelcomeView.swift
//  Flicksy
//

import AppKit
import SwiftUI

/// A short, native tour of Flicksy's core workflow. The view owns only the
/// current page; presentation and completion are coordinated by `BrowserModel`.
struct WelcomeView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page = 0

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                pageContent
                    .id(page)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Divider()

            footer
                .padding(.horizontal, 22)
                .frame(height: 68)
        }
        .frame(width: 640, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case 0:
            WelcomePage(
                title: "Your media, instantly in view",
                description: "Browse images, video, and audio right where they live on your Mac—no imports, uploads, or library to maintain."
            ) {
                BrowseInPlaceIllustration()
            }
        case 1:
            WelcomePage(
                title: "Find the right moment fast",
                description: "Skim video from its thumbnail, see audio as a waveform, and press Space to preview without breaking your flow."
            ) {
                FastPreviewIllustration()
            }
        default:
            WelcomePage(
                title: "Organize without moving a thing",
                description: "Favorite, tag, and collect media across folders while every original stays exactly where you put it."
            ) {
                OrganizeIllustration()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Skip") {
                model.completeWelcome()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.primary : Color.secondary.opacity(0.28))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(page + 1) of \(pageCount)")

            Spacer()

            if page > 0 {
                Button("Back") {
                    move(to: page - 1)
                }
            }

            if page < pageCount - 1 {
                Button("Continue") {
                    move(to: page + 1)
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Add Folder…") {
                    addFolder()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985))
    }

    private func move(to destination: Int) {
        let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.18)
        withAnimation(animation) {
            page = destination
        }
    }

    private func addFolder() {
        guard let url = model.addRootFolder() else { return }
        model.selectedSource = .folder(url.path)
        model.completeWelcome()
    }
}

private struct WelcomePage<Illustration: View>: View {
    let title: String
    let description: String
    @ViewBuilder let illustration: Illustration

    var body: some View {
        VStack(spacing: 0) {
            illustration
                .frame(height: 252)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .tracking(-0.5)
                .multilineTextAlignment(.center)

            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 470)
                .padding(.top, 10)
        }
        .padding(.horizontal, 44)
        .padding(.top, 24)
        .padding(.bottom, 30)
    }
}

private struct BrowseInPlaceIllustration: View {
    var body: some View {
        ZStack {
            WelcomeGlow(colors: [.blue, .purple])

            HStack(spacing: 16) {
                MediaTypeTile(systemImage: "photo", color: .blue, rotation: -5)
                AppIconTile()
                    .offset(y: -8)
                MediaTypeTile(systemImage: "waveform", color: .purple, rotation: 5)
            }
        }
    }
}

private struct FastPreviewIllustration: View {
    private let waveHeights: [CGFloat] = [12, 24, 38, 20, 45, 30, 52, 25, 42, 18, 34, 22, 46, 28, 16]

    var body: some View {
        ZStack {
            WelcomeGlow(colors: [.cyan, .blue])

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    previewTile(systemImage: "mountain.2.fill", playhead: 0.32)
                    previewTile(systemImage: "building.2.fill", playhead: 0.68)
                }

                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                    ForEach(Array(waveHeights.enumerated()), id: \.offset) { _, height in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: 3, height: height)
                    }
                    Text("Space")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.background, in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(.primary.opacity(0.12))
                        }
                        .padding(.leading, 10)
                }
                .frame(width: 310, height: 55)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(.primary.opacity(0.08))
                }
            }
        }
    }

    private func previewTile(systemImage: String, playhead: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.62))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 2)
                .padding(.vertical, 10)
                .offset(x: 140 * playhead)
        }
        .frame(width: 140, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.07), radius: 10, y: 5)
    }
}

private struct OrganizeIllustration: View {
    var body: some View {
        ZStack {
            WelcomeGlow(colors: [.pink, .orange])

            HStack(spacing: 13) {
                featureCard("star.fill", color: .yellow, label: "Favorites")
                featureCard("tag.fill", color: .purple, label: "Tags")
                featureCard("rectangle.stack.fill", color: .blue, label: "Collections")
            }
        }
    }

    private func featureCard(_ symbol: String, color: Color, label: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 58, height: 58)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 130, height: 134)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.07), radius: 12, y: 6)
    }
}

private struct AppIconTile: View {
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 112, height: 112)
            .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
    }
}

private struct MediaTypeTile: View {
    let systemImage: String
    let color: Color
    let rotation: Double

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 94, height: 94)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(.primary.opacity(0.08))
            }
            .rotationEffect(.degrees(rotation))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
    }
}

private struct WelcomeGlow: View {
    let colors: [Color]

    var body: some View {
        ZStack {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Circle()
                    .fill(color.opacity(0.14))
                    .frame(width: 190, height: 190)
                    .blur(radius: 32)
                    .offset(x: index == 0 ? -70 : 70, y: index == 0 ? 10 : -10)
            }
        }
    }
}

#Preview {
    WelcomeView()
        .environment(BrowserModel())
}

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

    private let pageCount = 4

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
                description: "Press ⌘J to Jump to any folder or collection, or ⌘K and type a filename to open one specific clip from anywhere."
            ) {
                FastFindIllustration()
            }
        case 2:
            WelcomePage(
                title: "Preview and compare at a glance",
                description: "Press Space to view your selection. Select multiple images and press ⇧Space to compare them in a sensible layout automatically."
            ) {
                PreviewComparisonIllustration()
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

private struct FastFindIllustration: View {
    var body: some View {
        ZStack {
            WelcomeGlow(colors: [.cyan, .blue])

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("Jump to")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        WelcomeKeycap("⌘J")
                    }

                    Divider()
                    destinationRow("Favorites", icon: "star.fill")
                    destinationRow("Downloads", icon: "arrow.down.circle")
                    destinationRow("Launch assets", icon: "folder.fill")
                }
                .padding(14)
                .frame(width: 242, height: 160)
                .welcomePanel()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text("hero-shot.mov")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                        Spacer()
                        WelcomeKeycap("⌘K")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 35)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.10)) }

                    HStack(spacing: 10) {
                        Image(systemName: "film.fill")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("hero-shot.mov")
                                .font(.system(size: 12, weight: .medium))
                            Text("Launch assets")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(9)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    Text("Find and open a single clip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(width: 242, height: 160)
                .welcomePanel()
            }
        }
    }

    private func destinationRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12))
            Spacer()
        }
    }
}

private struct PreviewComparisonIllustration: View {
    var body: some View {
        ZStack {
            WelcomeGlow(colors: [.indigo, .purple])

            VStack(spacing: 15) {
                HStack(spacing: 8) {
                    comparisonTile("mountain.2.fill", color: .indigo)
                    comparisonTile("building.2.fill", color: .purple)
                }
                .padding(8)
                .frame(width: 340, height: 126)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)) }
                .shadow(color: .black.opacity(0.08), radius: 12, y: 6)

                HStack(spacing: 12) {
                    shortcutLabel(keys: ["Space"], title: "Preview")

                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: 24)

                    shortcutLabel(keys: ["⇧", "Space"], title: "Compare")
                }
                .padding(.horizontal, 14)
                .frame(height: 45)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.08)) }
            }
        }
    }

    private func comparisonTile(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 35, weight: .light))
            .foregroundStyle(color.opacity(0.68))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func shortcutLabel(keys: [String], title: String) -> some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { WelcomeKeycap($0) }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }
}

private struct WelcomeKeycap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 23, minHeight: 22)
            .background(.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.12)) }
    }
}

private extension View {
    func welcomePanel() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)) }
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

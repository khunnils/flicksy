//
//  WaveformView.swift
//  MediaBrowser
//

import SwiftUI

/// Draws normalized peaks as vertical bars with a playhead, and maps horizontal
/// positions back to a position in the clip (spec sections 14 and 15).
///
/// Bars are accumulated into two `Path`s — played and unplayed — and each is
/// filled once, so a row costs two draw calls regardless of how many bars it
/// shows. Hover is local state because it is purely a visual affordance; only a
/// click reaches the caller.
struct WaveformView: View {
    /// Normalized 0...1 peaks, or empty while they are still being generated.
    let peaks: [Float]

    /// Played fraction of the clip, 0...1.
    let progress: Double

    /// Called with the 0...1 position the user clicked.
    let onSeek: (Double) -> Void

    @State private var hoverFraction: Double?
    @State private var width: CGFloat = 0

    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1

    /// Keeps silent passages visible as a hairline instead of a gap.
    private let minimumBarHeight: CGFloat = 1.5

    var body: some View {
        Canvas(opaque: false) { context, size in
            draw(in: &context, size: size)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                hoverFraction = fraction(atX: location.x)
            case .ended:
                hoverFraction = nil
            }
        }
        .gesture(
            SpatialTapGesture(coordinateSpace: .local).onEnded { value in
                onSeek(fraction(atX: value.location.x))
            }
        )
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        guard !peaks.isEmpty else {
            drawBaseline(in: &context, size: size)
            return
        }

        let step = barWidth + barSpacing
        let barCount = max(1, Int((size.width + barSpacing) / step))
        let playedWidth = size.width * clamp(progress)

        var played = Path()
        var unplayed = Path()

        for index in 0..<barCount {
            let height = max(minimumBarHeight, CGFloat(peak(forBar: index, of: barCount)) * size.height)
            let rect = CGRect(
                x: CGFloat(index) * step,
                y: (size.height - height) / 2,
                width: barWidth,
                height: height
            )
            let bar = Path(roundedRect: rect, cornerRadius: barWidth / 2, style: .continuous)

            if rect.midX <= playedWidth {
                played.addPath(bar)
            } else {
                unplayed.addPath(bar)
            }
        }

        context.fill(unplayed, with: .color(.secondary))
        context.fill(played, with: .color(.accentColor))

        if progress > 0 {
            drawPlayhead(in: &context, size: size, fraction: progress, color: .accentColor)
        }
        if let hoverFraction {
            drawPlayhead(in: &context, size: size, fraction: hoverFraction, color: .primary.opacity(0.7))
        }
    }

    /// Shown while peaks are generating, so the row does not change height when
    /// the waveform arrives.
    private func drawBaseline(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(x: 0, y: (size.height - 1) / 2, width: size.width, height: 1)
        context.fill(Path(rect), with: .color(.secondary.opacity(0.3)))
    }

    private func drawPlayhead(in context: inout GraphicsContext, size: CGSize, fraction: Double, color: Color) {
        let x = size.width * clamp(fraction)
        let rect = CGRect(x: min(x, size.width - 1), y: 0, width: 1, height: size.height)
        context.fill(Path(rect), with: .color(color))
    }

    // MARK: - Geometry

    /// Peak for one drawn bar: the loudest of the peaks that fall inside it, so
    /// transients survive being squeezed into fewer bars than there are peaks.
    private func peak(forBar index: Int, of barCount: Int) -> Float {
        let start = index * peaks.count / barCount
        guard start < peaks.count else { return 0 }
        let end = min(peaks.count, max(start + 1, (index + 1) * peaks.count / barCount))
        return peaks[start..<end].max() ?? 0
    }

    private func fraction(atX x: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return clamp(x / width)
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

//
//  WaveformView.swift
//  MediaBrowser
//

import AppKit
import SwiftUI

/// Draws normalized peaks as vertical bars with a playhead, and maps horizontal
/// positions back to a position in the clip (spec sections 14 and 15).
///
/// Bars are accumulated into two `Path`s — played and unplayed — and each is
/// filled once, so a row costs two draw calls regardless of how many bars it
/// shows. Hover is local state because it is purely a visual affordance; only a
/// click reaches the caller. Optional in/out handles sit above the canvas so
/// dragging a bound does not seek.
struct WaveformView: View {
    /// Normalized 0...1 peaks, or empty while they are still being generated.
    let peaks: [Float]

    /// Played fraction of the clip, 0...1.
    let progress: Double

    /// Inclusive in/out range in 0...1. When `onSelectionChange` is nil the
    /// range is display-only and handles are hidden.
    var selection: ClosedRange<Double> = 0...1

    /// Smallest allowed selection width, as a 0...1 fraction of the clip.
    var minimumSelectionSpan: Double = 0.005

    /// Called with the 0...1 position the user clicked.
    let onSeek: (Double) -> Void

    /// When set, start/end handles are shown and drags report a new range.
    var onSelectionChange: ((ClosedRange<Double>) -> Void)? = nil

    @State private var hoverFraction: Double?
    @State private var width: CGFloat = 0

    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1

    /// Keeps silent passages visible as a hairline instead of a gap.
    private let minimumBarHeight: CGFloat = 1.5

    /// Visual grip is 3pt; the hit target extends several pixels on each side
    /// so the cursor does not have to sit exactly on the marker.
    private let handleHitWidth: CGFloat = 20

    private var showsHandles: Bool { onSelectionChange != nil }

    var body: some View {
        ZStack(alignment: .leading) {
            Canvas(opaque: false) { context, size in
                draw(in: &context, size: size)
            }

            if showsHandles, width > 0 {
                WaveformHandle(
                    x: width * CGFloat(clamp(selection.lowerBound)) - handleHitWidth / 2,
                    hitWidth: handleHitWidth,
                    canvasSpace: Self.canvasSpace
                ) { locationX in
                    moveHandle(.start, to: fraction(atX: locationX))
                }
                WaveformHandle(
                    x: width * CGFloat(clamp(selection.upperBound)) - handleHitWidth / 2,
                    hitWidth: handleHitWidth,
                    canvasSpace: Self.canvasSpace
                ) { locationX in
                    moveHandle(.end, to: fraction(atX: locationX))
                }
            }
        }
        .coordinateSpace(name: Self.canvasSpace)
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
                onSeek(clampedSeek(fraction(atX: value.location.x)))
            }
        )
    }

    // MARK: - Handles

    private static let canvasSpace = "waveform-canvas"

    private enum HandleEdge {
        case start, end
    }

    private func moveHandle(_ edge: HandleEdge, to raw: Double) {
        let span = max(minimumSelectionSpan, 0.001)
        let value = clamp(raw)
        let next: ClosedRange<Double>
        switch edge {
        case .start:
            let start = min(value, selection.upperBound - span)
            next = max(0, start)...selection.upperBound
        case .end:
            let end = max(value, selection.lowerBound + span)
            next = selection.lowerBound...min(1, end)
        }
        onSelectionChange?(next)
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        guard !peaks.isEmpty else {
            drawBaseline(in: &context, size: size)
            drawSelectionShade(in: &context, size: size)
            return
        }

        let step = barWidth + barSpacing
        let barCount = max(1, Int((size.width + barSpacing) / step))
        let playedWidth = size.width * clamp(progress)
        let selectionStart = size.width * clamp(selection.lowerBound)
        let selectionEnd = size.width * clamp(selection.upperBound)

        var played = Path()
        var unplayed = Path()
        var outside = Path()

        for index in 0..<barCount {
            let height = max(minimumBarHeight, CGFloat(peak(forBar: index, of: barCount)) * size.height)
            let rect = CGRect(
                x: CGFloat(index) * step,
                y: (size.height - height) / 2,
                width: barWidth,
                height: height
            )
            let bar = Path(roundedRect: rect, cornerRadius: barWidth / 2, style: .continuous)
            let insideSelection = rect.midX >= selectionStart && rect.midX <= selectionEnd

            if !insideSelection {
                outside.addPath(bar)
            } else if rect.midX <= playedWidth {
                played.addPath(bar)
            } else {
                unplayed.addPath(bar)
            }
        }

        context.fill(outside, with: .color(.secondary.opacity(0.28)))
        context.fill(unplayed, with: .color(.secondary))
        context.fill(played, with: .color(.accentColor))

        drawSelectionShade(in: &context, size: size)

        if progress > 0 {
            drawPlayhead(in: &context, size: size, fraction: progress, color: .accentColor)
        }
        if let hoverFraction {
            drawPlayhead(in: &context, size: size, fraction: hoverFraction, color: .primary.opacity(0.7))
        }
    }

    private func drawSelectionShade(in context: inout GraphicsContext, size: CGSize) {
        let start = size.width * clamp(selection.lowerBound)
        let end = size.width * clamp(selection.upperBound)
        let rect = CGRect(x: start, y: 0, width: max(0, end - start), height: size.height)
        context.fill(Path(rect), with: .color(.accentColor.opacity(0.12)))
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

    private func clampedSeek(_ value: Double) -> Double {
        min(max(value, selection.lowerBound), selection.upperBound)
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// Narrow in/out grip. Kept as its own view so the waveform body stays
/// type-checkable and so the handle's hit target does not cover the canvas.
private struct WaveformHandle: View {
    let x: CGFloat
    let hitWidth: CGFloat
    let canvasSpace: String
    let onDrag: (CGFloat) -> Void

    @State private var isHovering = false

    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3)
            .frame(width: hitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .help("Drag to set the play range")
            .offset(x: x)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(canvasSpace))
                    .onChanged { value in
                        onDrag(value.location.x)
                    }
            )
    }
}

/// Quiet placeholder shown while peaks are still being generated. A faint
/// waveform silhouette breathes and a soft highlight travels across it, then
/// the real bars fade in over the top.
struct WaveformLoadingView: View {
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1
    private let minimumBarHeight: CGFloat = 1.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: false)) { timeline in
            Canvas(opaque: false) { context, size in
                draw(
                    in: &context,
                    size: size,
                    time: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
        .accessibilityLabel("Loading waveform")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }

        let step = barWidth + barSpacing
        let barCount = max(1, Int((size.width + barSpacing) / step))
        let breathe = 0.86 + 0.14 * sin(time * 1.05)
        let scan = time.truncatingRemainder(dividingBy: 3.2) / 3.2

        var bars = Path()
        for index in 0..<barCount {
            let x = Double(index) / Double(max(barCount - 1, 1))
            let height = max(minimumBarHeight, placeholderHeight(x: x, breathe: breathe, scan: scan) * size.height)
            bars.addPath(
                Path(roundedRect: CGRect(
                    x: CGFloat(index) * step,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                ), cornerRadius: barWidth / 2, style: .continuous)
            )
        }

        context.fill(bars, with: .color(.secondary.opacity(0.28)))
    }

    /// Deterministic silhouette so it reads as a waveform, not a uniform equalizer.
    private func placeholderHeight(x: Double, breathe: Double, scan: Double) -> CGFloat {
        let shape = 0.18
            + 0.16 * sin(x * 6.8)
            + 0.09 * sin(x * 17.4 + 0.8)
            + 0.05 * abs(sin(x * 37.0 + 1.3))
        let distance = min(abs(x - scan), 1 - abs(x - scan))
        let highlight = exp(-pow(distance * 12, 2))
        return CGFloat(min(0.72, shape * breathe + highlight * 0.16))
    }
}

//
//  ZoomableImage.swift
//  MediaBrowser
//

import SwiftUI
import AppKit

/// Fit / 100% / pinch-zoom / drag-pan image display (spec section 17).
///
/// `zoom` is relative to fit-to-window: 1 is fit, and 100% is the scale at which
/// one image pixel occupies one SwiftUI point. State is local so navigating to
/// the next still resets it via the caller's `.id(item.id)`.
struct ZoomableImage: View {
    let image: NSImage
    let nativeSize: CGSize

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let fitted = fitScale(container: geo.size)
            let currentZoom = clampedZoom(zoom * pinch, fitScale: fitted)
            let displayed = CGSize(
                width: nativeSize.width * fitted * currentZoom,
                height: nativeSize.height * fitted * currentZoom
            )
            let currentPan = clampedPan(
                CGSize(width: pan.width + drag.width, height: pan.height + drag.height),
                displayed: displayed,
                container: geo.size
            )

            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(currentZoom * fitted > 1.25 ? .none : .high)
                    .frame(width: displayed.width, height: displayed.height)
                    .offset(currentPan)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .pointerStyle(drag != .zero ? .grabActive : (currentZoom > 1.02 ? .grabIdle : .default))
            .gesture(magnifyGesture(fitScale: fitted, container: geo.size))
            .simultaneousGesture(panGesture(displayed: displayed, container: geo.size))
            .onTapGesture(count: 2) {
                toggleFitAndActual(fitScale: fitted)
            }
            .overlay(alignment: .bottomTrailing) {
                zoomToggle(fitScale: fitted)
            }
        }
        .clipped()
    }

    // MARK: - Chrome

    private func zoomToggle(fitScale: CGFloat) -> some View {
        Button(isFit ? "100%" : "Fit") {
            toggleFitAndActual(fitScale: fitScale)
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.45), in: Capsule())
        .help(isFit ? "Actual size" : "Fit to window")
        .padding(4)
    }

    private var isFit: Bool { abs(zoom - 1) < 0.04 }

    // MARK: - Gestures

    private func magnifyGesture(fitScale: CGFloat, container: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                zoom = clampedZoom(zoom * value.magnification, fitScale: fitScale)
                snapToFitIfNeeded()
                let displayed = CGSize(
                    width: nativeSize.width * fitScale * zoom,
                    height: nativeSize.height * fitScale * zoom
                )
                pan = clampedPan(pan, displayed: displayed, container: container)
            }
    }

    private func panGesture(displayed: CGSize, container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($drag) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                pan = clampedPan(
                    CGSize(width: pan.width + value.translation.width, height: pan.height + value.translation.height),
                    displayed: displayed,
                    container: container
                )
            }
    }

    private func toggleFitAndActual(fitScale: CGFloat) {
        if isFit {
            zoom = clampedZoom(actualSizeZoom(fitScale: fitScale), fitScale: fitScale)
        } else {
            zoom = 1
            pan = .zero
        }
    }

    private func snapToFitIfNeeded() {
        if zoom <= 1.02 {
            zoom = 1
            pan = .zero
        }
    }

    // MARK: - Geometry

    private func fitScale(container: CGSize) -> CGFloat {
        guard nativeSize.width > 0, nativeSize.height > 0,
              container.width > 0, container.height > 0
        else { return 1 }
        return min(container.width / nativeSize.width, container.height / nativeSize.height)
    }

    /// Zoom relative to fit at which one image pixel equals one point.
    private func actualSizeZoom(fitScale: CGFloat) -> CGFloat {
        guard fitScale > 0 else { return 1 }
        return 1 / fitScale
    }

    private func clampedZoom(_ value: CGFloat, fitScale: CGFloat) -> CGFloat {
        let actual = actualSizeZoom(fitScale: fitScale)
        let lower = min(1, actual)
        let upper = max(8, actual * 4)
        return min(max(value, lower), upper)
    }

    private func clampedPan(_ pan: CGSize, displayed: CGSize, container: CGSize) -> CGSize {
        let extraX = max(0, (displayed.width - container.width) / 2)
        let extraY = max(0, (displayed.height - container.height) / 2)
        return CGSize(
            width: min(max(pan.width, -extraX), extraX),
            height: min(max(pan.height, -extraY), extraY)
        )
    }
}

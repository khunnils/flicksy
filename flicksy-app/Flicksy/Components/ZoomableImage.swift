//
//  ZoomableImage.swift
//  MediaBrowser
//

import SwiftUI
import AppKit

/// Fit / 100% / pinch-zoom / drag-pan image display (spec section 17).
///
/// `zoom` is relative to fit-to-window: 1 is fit, and 100% is the scale at which
/// one image pixel occupies one SwiftUI point. Zoom lives in BrowserModel so the
/// window toolbar and keyboard shortcuts manipulate this same view.
struct ZoomableImage: View {
    let image: NSImage
    let nativeSize: CGSize

    @Environment(BrowserModel.self) private var model

    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        @Bindable var model = model

        GeometryReader { geo in
            let fitted = fitScale(container: geo.size)
            let zoom = model.isCropping ? 1.0 : clampedZoom(CGFloat(model.viewerImageZoom) * pinch, fitScale: fitted)
            let displayed = CGSize(
                width: nativeSize.width * fitted * zoom,
                height: nativeSize.height * fitted * zoom
            )
            let currentPan = model.isCropping
                ? CGSize.zero
                : clampedPan(
                    CGSize(width: pan.width + drag.width, height: pan.height + drag.height),
                    displayed: displayed,
                    container: geo.size
                )
            let imageOrigin = CGPoint(
                x: (geo.size.width - displayed.width) / 2 + currentPan.width,
                y: (geo.size.height - displayed.height) / 2 + currentPan.height
            )
            let imageFrame = CGRect(origin: imageOrigin, size: displayed)

            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(zoom * fitted > 1.25 ? .none : .high)
                    .frame(width: displayed.width, height: displayed.height)
                    .offset(currentPan)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                if model.isCropping {
                    ImageCropOverlay(
                        imageFrame: imageFrame,
                        imageSize: nativeSize,
                        normalizedRect: $model.cropNormalizedRect,
                        aspect: model.cropAspect
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .pointerStyle(
                model.isCropping
                    ? .default
                    : (drag != .zero ? .grabActive : (zoom > 1.02 ? .grabIdle : .default))
            )
            .gesture(magnifyGesture(fitScale: fitted, container: geo.size))
            .simultaneousGesture(panGesture(displayed: displayed, container: geo.size))
            .onTapGesture(count: 2) {
                guard !model.isCropping else { return }
                toggleFitAndActual(fitScale: fitted)
            }
            .onAppear {
                configureZoom(fitScale: fitted)
                model.updateCropImageSize(nativeSize)
            }
            .onChange(of: geo.size) { _, _ in configureZoom(fitScale: fitted) }
            .onChange(of: nativeSize) { _, newSize in
                configureZoom(fitScale: fitted)
                model.updateCropImageSize(newSize)
            }
            .onChange(of: model.viewerImageZoom) { _, newZoom in
                let resized = CGSize(
                    width: nativeSize.width * fitted * newZoom,
                    height: nativeSize.height * fitted * newZoom
                )
                pan = clampedPan(pan, displayed: resized, container: geo.size)
            }
            .onChange(of: model.isCropping) { _, cropping in
                if cropping { pan = .zero }
            }
        }
        .clipped()
    }

    // MARK: - Gestures

    private func magnifyGesture(fitScale: CGFloat, container: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in
                guard !model.isCropping else { return }
                state = value.magnification
            }
            .onEnded { value in
                guard !model.isCropping else { return }
                let zoom = clampedZoom(CGFloat(model.viewerImageZoom) * value.magnification, fitScale: fitScale)
                model.setViewerImageZoom(Double(zoom))
                let displayed = CGSize(
                    width: nativeSize.width * fitScale * CGFloat(model.viewerImageZoom),
                    height: nativeSize.height * fitScale * CGFloat(model.viewerImageZoom)
                )
                pan = clampedPan(pan, displayed: displayed, container: container)
            }
    }

    private func panGesture(displayed: CGSize, container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($drag) { value, state, _ in
                guard !model.isCropping else { return }
                state = value.translation
            }
            .onEnded { value in
                guard !model.isCropping else { return }
                pan = clampedPan(
                    CGSize(width: pan.width + value.translation.width, height: pan.height + value.translation.height),
                    displayed: displayed,
                    container: container
                )
            }
    }

    private func toggleFitAndActual(fitScale: CGFloat) {
        model.configureViewerImageZoom(fitScale: fitScale)
        model.toggleViewerImageFitAndActualSize()
        if model.isViewerImageFit {
            pan = .zero
        }
    }

    private func configureZoom(fitScale: CGFloat) {
        model.configureViewerImageZoom(fitScale: fitScale)
        if model.isViewerImageFit || model.isCropping {
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

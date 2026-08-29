//
//  ImageCropOverlay.swift
//  Flicksy
//

import SwiftUI

/// Interactive crop guide drawn over the fitted still. Coordinates are normalized
/// to the oriented image (0…1, top-left origin) so Apply can crop the original file.
struct ImageCropOverlay: View {
    let imageFrame: CGRect
    let imageSize: CGSize

    @Binding var normalizedRect: CGRect
    var aspect: CropAspectRatio

    @State private var drag: DragSession?

    private let handleSize: CGFloat = 10
    private let minNormalizedSide: CGFloat = 0.05

    var body: some View {
        let crop = cropFrame

        ZStack {
            dimming(outside: crop)

            Rectangle()
                .fill(.white.opacity(0.001))
                .frame(width: crop.width, height: crop.height)
                .position(x: crop.midX, y: crop.midY)
                .gesture(moveGesture())

            cropBorder(crop)

            ForEach(Handle.allCases, id: \.self) { handle in
                handleView(handle, in: crop)
            }
        }
        .frame(width: imageFrame.width, height: imageFrame.height)
        .position(x: imageFrame.midX, y: imageFrame.midY)
        .onAppear { ensureValidRect() }
        .onChange(of: aspect) { _, _ in applyAspectPreservingCenter() }
        .onChange(of: imageSize) { _, _ in ensureValidRect() }
    }

    // MARK: - Drawing

    private var cropFrame: CGRect {
        CGRect(
            x: normalizedRect.origin.x * imageFrame.width,
            y: normalizedRect.origin.y * imageFrame.height,
            width: normalizedRect.width * imageFrame.width,
            height: normalizedRect.height * imageFrame.height
        )
    }

    private func dimming(outside crop: CGRect) -> some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(crop)
            context.fill(path, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
        }
        // Absorb clicks outside the guide so they do not pan the still underneath.
        .contentShape(Rectangle())
    }

    private func cropBorder(_ crop: CGRect) -> some View {
        ZStack {
            Rectangle()
                .strokeBorder(.white.opacity(0.95), lineWidth: 1)
                .frame(width: crop.width, height: crop.height)
                .position(x: crop.midX, y: crop.midY)

            // Rule-of-thirds guides.
            Path { path in
                for i in 1...2 {
                    let x = crop.minX + crop.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: crop.minY))
                    path.addLine(to: CGPoint(x: x, y: crop.maxY))
                    let y = crop.minY + crop.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: crop.minX, y: y))
                    path.addLine(to: CGPoint(x: crop.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func handleView(_ handle: Handle, in crop: CGRect) -> some View {
        let point = handle.point(in: crop)
        return Circle()
            .fill(.white)
            .frame(width: handleSize, height: handleSize)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .position(point)
            .highPriorityGesture(resizeGesture(handle))
    }

    // MARK: - Gestures

    private func moveGesture() -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil {
                    drag = DragSession(kind: .move, startRect: normalizedRect, startLocation: value.startLocation)
                }
                guard let drag, drag.kind == .move else { return }
                let dx = (value.location.x - drag.startLocation.x) / imageFrame.width
                let dy = (value.location.y - drag.startLocation.y) / imageFrame.height
                normalizedRect = clamped(
                    CGRect(
                        x: drag.startRect.origin.x + dx,
                        y: drag.startRect.origin.y + dy,
                        width: drag.startRect.width,
                        height: drag.startRect.height
                    )
                )
            }
            .onEnded { _ in drag = nil }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil {
                    drag = DragSession(kind: .resize(handle), startRect: normalizedRect, startLocation: value.startLocation)
                }
                guard let drag, case .resize(let active) = drag.kind, active == handle else { return }
                let dx = (value.location.x - drag.startLocation.x) / imageFrame.width
                let dy = (value.location.y - drag.startLocation.y) / imageFrame.height
                normalizedRect = resized(from: drag.startRect, handle: handle, dx: dx, dy: dy)
            }
            .onEnded { _ in drag = nil }
    }

    // MARK: - Geometry

    private func ensureValidRect() {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        if normalizedRect.width < minNormalizedSide || normalizedRect.height < minNormalizedSide {
            normalizedRect = defaultRect()
        } else {
            normalizedRect = clamped(normalizedRect)
        }
    }

    private func applyAspectPreservingCenter() {
        let center = CGPoint(x: normalizedRect.midX, y: normalizedRect.midY)
        let next = Self.largestNormalizedRect(aspect: aspect, imageSize: imageSize, scale: 0.92)
        normalizedRect = clamped(
            CGRect(
                x: center.x - next.width / 2,
                y: center.y - next.height / 2,
                width: next.width,
                height: next.height
            )
        )
    }

    private func defaultRect() -> CGRect {
        Self.largestNormalizedRect(aspect: aspect, imageSize: imageSize, scale: 0.92)
    }

    private func resized(from start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = start.minX
        var minY = start.minY
        var maxX = start.maxX
        var maxY = start.maxY

        if handle.affectsMinX { minX = start.minX + dx }
        if handle.affectsMaxX { maxX = start.maxX + dx }
        if handle.affectsMinY { minY = start.minY + dy }
        if handle.affectsMaxY { maxY = start.maxY + dy }

        if let ratio = aspect.widthOverHeight(imageSize: imageSize) {
            let imageAspect = imageSize.width / max(imageSize.height, 1)
            // Convert normalized deltas into a consistent aspect lock around the
            // opposite corner / edge anchor.
            return aspectLockedResize(
                start: start,
                handle: handle,
                minX: minX,
                minY: minY,
                maxX: maxX,
                maxY: maxY,
                ratio: ratio,
                imageAspect: imageAspect
            )
        }

        if maxX - minX < minNormalizedSide {
            if handle.affectsMinX { minX = maxX - minNormalizedSide } else { maxX = minX + minNormalizedSide }
        }
        if maxY - minY < minNormalizedSide {
            if handle.affectsMinY { minY = maxY - minNormalizedSide } else { maxY = minY + minNormalizedSide }
        }

        return clamped(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    private func aspectLockedResize(
        start: CGRect,
        handle: Handle,
        minX: CGFloat,
        minY: CGFloat,
        maxX: CGFloat,
        maxY: CGFloat,
        ratio: CGFloat,
        imageAspect: CGFloat
    ) -> CGRect {
        // Target width/height in normalized space where height = width * imageAspect / ratio.
        let heightForWidth: (CGFloat) -> CGFloat = { $0 * imageAspect / ratio }
        let widthForHeight: (CGFloat) -> CGFloat = { $0 * ratio / imageAspect }

        var width = max(maxX - minX, minNormalizedSide)
        var height = heightForWidth(width)

        switch handle {
        case .top, .bottom:
            height = max(maxY - minY, minNormalizedSide)
            width = widthForHeight(height)
        case .left, .right:
            width = max(maxX - minX, minNormalizedSide)
            height = heightForWidth(width)
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // Drive from the dominant drag axis so corner pulls feel natural.
            let proposedWidth = max(maxX - minX, minNormalizedSide)
            let proposedHeight = max(maxY - minY, minNormalizedSide)
            if abs(proposedWidth - start.width) >= abs(proposedHeight - start.height) {
                width = proposedWidth
                height = heightForWidth(width)
            } else {
                height = proposedHeight
                width = widthForHeight(height)
            }
        }

        var rect: CGRect
        switch handle {
        case .topLeft:
            rect = CGRect(x: start.maxX - width, y: start.maxY - height, width: width, height: height)
        case .topRight:
            rect = CGRect(x: start.minX, y: start.maxY - height, width: width, height: height)
        case .bottomLeft:
            rect = CGRect(x: start.maxX - width, y: start.minY, width: width, height: height)
        case .bottomRight:
            rect = CGRect(x: start.minX, y: start.minY, width: width, height: height)
        case .top:
            rect = CGRect(x: start.midX - width / 2, y: start.maxY - height, width: width, height: height)
        case .bottom:
            rect = CGRect(x: start.midX - width / 2, y: start.minY, width: width, height: height)
        case .left:
            rect = CGRect(x: start.maxX - width, y: start.midY - height / 2, width: width, height: height)
        case .right:
            rect = CGRect(x: start.minX, y: start.midY - height / 2, width: width, height: height)
        }
        return clamped(rect)
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        var width = min(max(rect.width, minNormalizedSide), 1)
        var height = min(max(rect.height, minNormalizedSide), 1)
        if let ratio = aspect.widthOverHeight(imageSize: imageSize), imageSize.height > 0 {
            let imageAspect = imageSize.width / imageSize.height
            let heightFromWidth = width * imageAspect / ratio
            let widthFromHeight = height * ratio / imageAspect
            if abs(heightFromWidth - height) > abs(widthFromHeight - width) {
                width = min(widthFromHeight, 1)
                height = width * imageAspect / ratio
            } else {
                height = min(heightFromWidth, 1)
                width = height * ratio / imageAspect
            }
            width = min(max(width, minNormalizedSide), 1)
            height = min(max(height, minNormalizedSide), 1)
        }
        let x = min(max(rect.origin.x, 0), 1 - width)
        let y = min(max(rect.origin.y, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Types

    private enum Handle: CaseIterable, Hashable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

        var affectsMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var affectsMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
        var affectsMinY: Bool { self == .topLeft || self == .top || self == .topRight }
        var affectsMaxY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

        func point(in crop: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: crop.minX, y: crop.minY)
            case .top: CGPoint(x: crop.midX, y: crop.minY)
            case .topRight: CGPoint(x: crop.maxX, y: crop.minY)
            case .left: CGPoint(x: crop.minX, y: crop.midY)
            case .right: CGPoint(x: crop.maxX, y: crop.midY)
            case .bottomLeft: CGPoint(x: crop.minX, y: crop.maxY)
            case .bottom: CGPoint(x: crop.midX, y: crop.maxY)
            case .bottomRight: CGPoint(x: crop.maxX, y: crop.maxY)
            }
        }
    }

    private struct DragSession {
        enum Kind: Equatable {
            case move
            case resize(Handle)
        }

        let kind: Kind
        let startRect: CGRect
        let startLocation: CGPoint
    }
}

extension ImageCropOverlay {
    /// Largest centered crop of `aspect` that fits in the image, scaled by `scale`.
    static func largestNormalizedRect(
        aspect: CropAspectRatio,
        imageSize: CGSize,
        scale: CGFloat = 0.92
    ) -> CGRect {
        guard let ratio = aspect.widthOverHeight(imageSize: imageSize) else {
            let inset = (1 - scale) / 2
            return CGRect(x: inset, y: inset, width: scale, height: scale)
        }
        let imageAspect = imageSize.width / max(imageSize.height, 1)
        let width: CGFloat
        let height: CGFloat
        if ratio > imageAspect {
            width = scale
            height = width * imageAspect / ratio
        } else {
            height = scale
            width = height * ratio / imageAspect
        }
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}

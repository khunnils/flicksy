//
//  ImageResizeModels.swift
//  Flicksy
//

import CoreGraphics
import Foundation

/// One image targeted by the modal resize workflow.
struct ImageResizeRequest: Identifiable, Equatable, Sendable {
    let item: MediaItem

    nonisolated var id: String { item.id }
}

/// Testable dimension editing state shared by the resize sheet's text fields.
struct ImageResizeDraft: Equatable, Sendable {
    let sourceWidth: Int
    let sourceHeight: Int
    private(set) var widthText: String
    private(set) var heightText: String
    var isAspectRatioLocked = true

    nonisolated init?(sourceSize: CGSize) {
        let width = Int(sourceSize.width.rounded())
        let height = Int(sourceSize.height.rounded())
        guard width > 0, height > 0 else { return nil }
        sourceWidth = width
        sourceHeight = height
        widthText = String(width)
        heightText = String(height)
    }

    nonisolated var width: Int? { Self.positiveInteger(widthText) }
    nonisolated var height: Int? { Self.positiveInteger(heightText) }

    nonisolated var targetSize: CGSize? {
        guard let width, let height else { return nil }
        return CGSize(width: width, height: height)
    }

    nonisolated var isChanged: Bool {
        guard let width, let height else { return false }
        return width != sourceWidth || height != sourceHeight
    }

    nonisolated var canApply: Bool { targetSize != nil && isChanged }

    mutating func setWidthText(_ value: String) {
        widthText = value
        guard isAspectRatioLocked, let width = Self.positiveInteger(value) else { return }
        heightText = String(Self.scaled(width, from: sourceWidth, to: sourceHeight))
    }

    mutating func setHeightText(_ value: String) {
        heightText = value
        guard isAspectRatioLocked, let height = Self.positiveInteger(value) else { return }
        widthText = String(Self.scaled(height, from: sourceHeight, to: sourceWidth))
    }

    nonisolated private static func positiveInteger(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy(\.isNumber),
              let value = Int(trimmed),
              value > 0
        else { return nil }
        return value
    }

    nonisolated private static func scaled(_ value: Int, from source: Int, to other: Int) -> Int {
        let ratio = Double(other) / Double(source)
        let result = (Double(value) * ratio).rounded()
        if !result.isFinite || result >= Double(Int.max) { return Int.max }
        return max(1, Int(result))
    }
}

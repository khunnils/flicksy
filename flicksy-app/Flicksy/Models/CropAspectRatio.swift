//
//  CropAspectRatio.swift
//  Flicksy
//

import CoreGraphics
import Foundation

/// Aspect lock for the image crop guide. `free` is unconstrained; `original`
/// matches the source image; the rest are common display and print ratios.
enum CropAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case free
    case original
    case square
    case ratio16x9
    case ratio9x16
    case ratio4x3
    case ratio3x4
    case ratio3x2
    case ratio2x3
    case ratio5x4
    case ratio4x5
    case ratio7x5
    case ratio5x7
    case isoLandscape
    case isoPortrait

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .ratio16x9: "16:9"
        case .ratio9x16: "9:16"
        case .ratio4x3: "4:3"
        case .ratio3x4: "3:4"
        case .ratio3x2: "3:2"
        case .ratio2x3: "2:3"
        case .ratio5x4: "5:4"
        case .ratio4x5: "4:5"
        case .ratio7x5: "7:5"
        case .ratio5x7: "5:7"
        case .isoLandscape: "A Series"
        case .isoPortrait: "A Series Portrait"
        }
    }

    /// Width ÷ height. `nil` for freeform; original is resolved from the image.
    func widthOverHeight(imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free:
            return nil
        case .original:
            guard imageSize.height > 0 else { return nil }
            return imageSize.width / imageSize.height
        case .square:
            return 1
        case .ratio16x9:
            return 16.0 / 9.0
        case .ratio9x16:
            return 9.0 / 16.0
        case .ratio4x3:
            return 4.0 / 3.0
        case .ratio3x4:
            return 3.0 / 4.0
        case .ratio3x2:
            return 3.0 / 2.0
        case .ratio2x3:
            return 2.0 / 3.0
        case .ratio5x4:
            return 5.0 / 4.0
        case .ratio4x5:
            return 4.0 / 5.0
        case .ratio7x5:
            return 7.0 / 5.0
        case .ratio5x7:
            return 5.0 / 7.0
        case .isoLandscape:
            return sqrt(2)
        case .isoPortrait:
            return 1 / sqrt(2)
        }
    }
}

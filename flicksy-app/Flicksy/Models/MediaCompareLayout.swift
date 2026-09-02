//
//  MediaCompareLayout.swift
//  Flicksy
//

import Foundation

/// Fixed comparison arrangements. Names are expressed as columns x rows.
enum MediaCompareLayout: String, CaseIterable, Identifiable, Sendable {
    case oneByTwo = "1x2"
    case twoByOne = "2x1"
    case twoByTwo = "2x2"
    case oneByThree = "1x3"
    case threeByOne = "3x1"

    var id: String { rawValue }

    var columns: Int {
        switch self {
        case .oneByTwo, .oneByThree: 1
        case .twoByOne, .twoByTwo: 2
        case .threeByOne: 3
        }
    }

    var rows: Int {
        switch self {
        case .twoByOne, .threeByOne: 1
        case .oneByTwo, .twoByTwo: 2
        case .oneByThree: 3
        }
    }

    var capacity: Int { columns * rows }
    var title: String { "\(columns) × \(rows)" }

    func isAvailable(for imageCount: Int) -> Bool {
        imageCount >= capacity
    }

    /// Resolve the requested automatic layout from item count and orientation.
    /// Unknown dimensions do not vote; ties fall back to the focused item, then
    /// the first item with dimensions, and finally the horizontal arrangement.
    nonisolated static func automatic(
        for items: [MediaItem],
        focusedItemID: MediaItem.ID?
    ) -> MediaCompareLayout {
        if items.count >= 4 { return .twoByTwo }

        let horizontal: MediaCompareLayout = items.count >= 3 ? .threeByOne : .twoByOne
        let vertical: MediaCompareLayout = items.count >= 3 ? .oneByThree : .oneByTwo

        var portraitOrSquare = 0
        var landscape = 0
        for item in items {
            guard let orientation = orientation(of: item) else { continue }
            switch orientation {
            case .landscape: landscape += 1
            case .portraitOrSquare: portraitOrSquare += 1
            }
        }

        if portraitOrSquare > landscape { return horizontal }
        if landscape > portraitOrSquare { return vertical }

        if let focusedItemID,
           let focused = items.first(where: { $0.id == focusedItemID }),
           let orientation = orientation(of: focused) {
            switch orientation {
            case .landscape: return vertical
            case .portraitOrSquare: return horizontal
            }
        }
        if let orientation = items.lazy.compactMap(orientation(of:)).first {
            switch orientation {
            case .landscape: return vertical
            case .portraitOrSquare: return horizontal
            }
        }
        return horizontal
    }

    private enum Orientation {
        case portraitOrSquare
        case landscape
    }

    private nonisolated static func orientation(of item: MediaItem) -> Orientation? {
        guard let width = item.width, let height = item.height, width > 0, height > 0 else {
            return nil
        }
        return width > height ? .landscape : .portraitOrSquare
    }
}

/// Pure slot-ordering helpers shared by BrowserModel and unit tests.
enum MediaComparisonAssignment {
    nonisolated static func initial(
        itemIDs: [MediaItem.ID],
        preferredItemID: MediaItem.ID,
        capacity: Int
    ) -> [MediaItem.ID] {
        var ordered = itemIDs
        if let index = ordered.firstIndex(of: preferredItemID) {
            ordered.remove(at: index)
            ordered.insert(preferredItemID, at: 0)
        }
        return Array(ordered.prefix(capacity))
    }

    nonisolated static func resized(
        assignments: [MediaItem.ID],
        allItemIDs: [MediaItem.ID],
        capacity: Int
    ) -> [MediaItem.ID] {
        var result = Array(
            assignments
                .filter(allItemIDs.contains)
                .prefix(capacity)
        )
        for id in allItemIDs where result.count < capacity && !result.contains(id) {
            result.append(id)
        }
        return result
    }

    nonisolated static func assigning(
        itemID: MediaItem.ID,
        toSlot index: Int,
        assignments: [MediaItem.ID],
        allItemIDs: [MediaItem.ID]
    ) -> [MediaItem.ID] {
        guard allItemIDs.contains(itemID), assignments.indices.contains(index) else {
            return assignments
        }
        var result = assignments
        if let source = result.firstIndex(of: itemID) {
            result.swapAt(source, index)
        } else {
            result[index] = itemID
        }
        return result
    }
}

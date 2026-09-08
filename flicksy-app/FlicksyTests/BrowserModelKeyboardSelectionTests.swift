//
//  BrowserModelKeyboardSelectionTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

@MainActor
final class BrowserModelKeyboardSelectionTests: XCTestCase {
    func testMoveFocusLeavesSelectionUnchanged() {
        let (model, items) = makeModel(itemCount: 6)
        model.selectItem(items[0])

        model.moveFocus(.right, columns: 3)

        XCTAssertEqual(model.selectedItemIDs, [items[0].id])
        XCTAssertEqual(model.selectionAnchorID, items[0].id)
        XCTAssertEqual(model.focusedItemID, items[1].id)
        XCTAssertTrue(model.selectionState(for: items[0].id).isSelected)
        XCTAssertFalse(model.selectionState(for: items[0].id).isFocused)
        XCTAssertFalse(model.selectionState(for: items[1].id).isSelected)
        XCTAssertTrue(model.selectionState(for: items[1].id).isFocused)
        XCTAssertTrue(model.isKeyboardMultiSelectActive)
    }

    func testMouseSelectionHidesKeyboardFocusOutline() {
        let (model, items) = makeModel(itemCount: 4)
        model.selectItem(items[0])
        model.moveFocus(.right, columns: 1)
        XCTAssertTrue(model.isKeyboardMultiSelectActive)

        model.selectItem(items[2])

        XCTAssertFalse(model.isKeyboardMultiSelectActive)
        XCTAssertFalse(model.selectionState(for: items[1].id).isFocused)
        XCTAssertFalse(model.selectionState(for: items[2].id).isFocused)
    }

    func testStandardArrowSelectionHidesKeyboardFocusOutline() {
        let (model, items) = makeModel(itemCount: 4)
        model.selectItem(items[0])
        XCTAssertFalse(model.selectionState(for: items[0].id).isFocused)

        model.moveFocus(.right, columns: 1)
        model.moveSelection(.right, columns: 1, extending: false)

        XCTAssertFalse(model.isKeyboardMultiSelectActive)
        XCTAssertFalse(model.selectionState(for: items[2].id).isFocused)
    }

    func testMoveFocusUsesGridColumnsForVerticalSteps() {
        let (model, items) = makeModel(itemCount: 6)
        model.selectItem(items[1])

        model.moveFocus(.down, columns: 3)

        XCTAssertEqual(model.selectedItemIDs, [items[1].id])
        XCTAssertEqual(model.focusedItemID, items[4].id)
    }

    func testMoveFocusClampsAtListEdges() {
        let (model, items) = makeModel(itemCount: 3, tab: .all)
        model.selectItem(items[2])

        model.moveFocus(.down, columns: 1)
        model.moveFocus(.right, columns: 1)

        XCTAssertEqual(model.focusedItemID, items[2].id)
        XCTAssertEqual(model.selectedItemIDs, [items[2].id])
    }

    func testToggleFocusedItemAddsAndRemovesWithoutMovingFocus() {
        let (model, items) = makeModel(itemCount: 4)
        model.selectItem(items[0])
        model.moveFocus(.right, columns: 1)

        model.toggleFocusedItemSelection()

        XCTAssertEqual(model.selectedItemIDs, [items[0].id, items[1].id])
        XCTAssertEqual(model.focusedItemID, items[1].id)
        XCTAssertEqual(model.selectionAnchorID, items[1].id)

        model.toggleFocusedItemSelection()

        XCTAssertEqual(model.selectedItemIDs, [items[0].id])
        XCTAssertEqual(model.focusedItemID, items[1].id)
        XCTAssertTrue(model.selectionState(for: items[1].id).isFocused)
        XCTAssertFalse(model.selectionState(for: items[1].id).isSelected)
    }

    func testToggleFocusedItemNoopsWithoutFocus() {
        let (model, _) = makeModel(itemCount: 3)

        model.toggleFocusedItemSelection()

        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertNil(model.focusedItemID)
    }

    func testArrowMoveStillReplacesSelection() {
        let (model, items) = makeModel(itemCount: 4)
        model.selectItem(items[0])
        model.moveFocus(.right, columns: 1)

        model.moveSelection(.right, columns: 1, extending: false)

        XCTAssertEqual(model.selectedItemIDs, [items[2].id])
        XCTAssertEqual(model.focusedItemID, items[2].id)
        XCTAssertEqual(model.selectionAnchorID, items[2].id)
        XCTAssertFalse(model.isKeyboardMultiSelectActive)
    }

    func testShiftArrowStillExtendsFromAnchor() {
        let (model, items) = makeModel(itemCount: 5)
        model.selectItem(items[0])
        model.moveFocus(.right, columns: 1)
        model.moveFocus(.right, columns: 1)

        model.moveSelection(.right, columns: 1, extending: true)

        XCTAssertEqual(model.selectedItemIDs, Set(items[0...3].map(\.id)))
        XCTAssertEqual(model.focusedItemID, items[3].id)
        XCTAssertEqual(model.selectionAnchorID, items[0].id)
    }

    func testAudioListingSupportsIndependentFocus() {
        let (model, items) = makeModel(itemCount: 4, type: .audio, tab: .audio)
        model.selectItem(items[0])

        model.moveFocus(.down, columns: 1)
        model.toggleFocusedItemSelection()

        XCTAssertEqual(model.selectedItemIDs, [items[0].id, items[1].id])
        XCTAssertEqual(model.focusedItemID, items[1].id)
        XCTAssertTrue(model.selectionState(for: items[1].id).isFocused)
    }

    func testCommandArrowMovesFocusWithoutChangingSelection() {
        let (model, items) = makeModel(itemCount: 4)
        model.selectItem(items[0])

        model.handleBrowserKeyboardArrow(
            .right,
            columns: 1,
            extend: false,
            option: false,
            command: true
        )

        XCTAssertEqual(model.selectedItemIDs, [items[0].id])
        XCTAssertEqual(model.focusedItemID, items[1].id)
        XCTAssertTrue(model.selectionState(for: items[1].id).isFocused)
        XCTAssertFalse(model.selectionState(for: items[1].id).isSelected)
    }

    func testCommandArrowMovesFocusEvenWhenAudioCanSeek() {
        let (model, items) = makeModel(itemCount: 4, type: .audio, tab: .audio)
        model.selectItem(items[0])
        XCTAssertTrue(model.canControlInspectorAudio)

        model.handleBrowserKeyboardArrow(
            .right,
            columns: 1,
            extend: false,
            option: false,
            command: true
        )

        XCTAssertEqual(model.selectedItemIDs, [items[0].id])
        XCTAssertEqual(model.focusedItemID, items[1].id)
        XCTAssertEqual(model.audioSeekRequestID, 0)
    }

    func testCommandShiftArrowJumpsAudioPlayhead() {
        let (model, items) = makeModel(itemCount: 4, type: .audio, tab: .audio)
        model.selectItem(items[0])
        let seekID = model.audioSeekRequestID

        model.handleBrowserKeyboardArrow(
            .right,
            columns: 1,
            extend: true,
            option: false,
            command: true
        )

        XCTAssertEqual(model.audioSeekKind, .end)
        XCTAssertEqual(model.audioSeekRequestID, seekID + 1)
        XCTAssertEqual(model.focusedItemID, items[0].id)
    }

    func testOptionArrowMovesFocusEvenWhenAudioCanSeek() {
        let (model, items) = makeModel(itemCount: 4, type: .audio, tab: .audio)
        model.selectItem(items[0])
        XCTAssertTrue(model.canControlInspectorAudio)

        model.handleBrowserKeyboardArrow(
            .down,
            columns: 1,
            extend: false,
            option: true,
            command: false
        )

        XCTAssertEqual(model.selectedItemIDs, [items[0].id])
        XCTAssertEqual(model.focusedItemID, items[1].id)
    }

    func testLibraryTabHelpDescribesEachView() {
        let helps = MediaLibraryTab.allCases.map(\.help)
        XCTAssertEqual(Set(helps).count, helps.count)
        XCTAssertTrue(MediaLibraryTab.all.help.localizedCaseInsensitiveContains("list"))
        XCTAssertTrue(MediaLibraryTab.visual.help.localizedCaseInsensitiveContains("grid"))
        XCTAssertTrue(MediaLibraryTab.audio.help.localizedCaseInsensitiveContains("waveform"))
    }

    func testLibraryTabsAreAvailableOnlyWhenSourceHasMatchingItems() {
        let (model, _) = makeModel(itemCount: 0, tab: .all)
        XCTAssertTrue(model.isLibraryTabAvailable(.all))
        XCTAssertFalse(model.isLibraryTabAvailable(.visual))
        XCTAssertFalse(model.isLibraryTabAvailable(.audio))

        model.replaceMediaItemsForTesting(makeItems(count: 2, type: .image), tab: .visual)
        XCTAssertTrue(model.isLibraryTabAvailable(.visual))
        XCTAssertFalse(model.isLibraryTabAvailable(.audio))

        model.replaceMediaItemsForTesting(makeItems(count: 1, type: .video), tab: .visual)
        XCTAssertTrue(model.isLibraryTabAvailable(.visual))
        XCTAssertFalse(model.isLibraryTabAvailable(.audio))

        model.replaceMediaItemsForTesting(makeItems(count: 2, type: .audio), tab: .audio)
        XCTAssertFalse(model.isLibraryTabAvailable(.visual))
        XCTAssertTrue(model.isLibraryTabAvailable(.audio))

        let mixed = makeItems(count: 1, type: .image) + makeItems(count: 1, type: .audio, namePrefix: "audio")
        model.replaceMediaItemsForTesting(mixed, tab: .all)
        XCTAssertTrue(model.isLibraryTabAvailable(.visual))
        XCTAssertTrue(model.isLibraryTabAvailable(.audio))
    }

    func testSelectLibraryTabIgnoresTabsWithoutMatchingItems() {
        let (model, _) = makeModel(itemCount: 2, type: .image, tab: .visual)

        model.selectLibraryTab(.audio)
        XCTAssertEqual(model.libraryTab, .visual)

        model.selectLibraryTab(.all)
        XCTAssertEqual(model.libraryTab, .all)
    }

    func testSearchDoesNotDisableLibraryTabsWhenSourceStillHasItems() {
        let mixed = makeItems(count: 1, type: .image) + makeItems(count: 1, type: .audio, namePrefix: "song")
        let (model, _) = makeModel(itemCount: 0, tab: .all)
        model.replaceMediaItemsForTesting(mixed, tab: .all)
        model.searchQuery = "song"

        XCTAssertTrue(model.visualItems.isEmpty)
        XCTAssertTrue(model.isLibraryTabAvailable(.visual))
        XCTAssertTrue(model.isLibraryTabAvailable(.audio))
    }

    func testEmptySpecializedTabFallsBackToAPopulatedView() {
        let (model, _) = makeModel(itemCount: 2, type: .image, tab: .visual)

        model.replaceMediaItemsForTesting(
            makeItems(count: 2, type: .audio),
            tab: .visual,
            preserveTab: false
        )
        XCTAssertEqual(model.libraryTab, .audio)

        model.replaceMediaItemsForTesting([], tab: .audio, preserveTab: false)
        XCTAssertEqual(model.libraryTab, .all)
    }

    private func makeModel(
        itemCount: Int,
        type: MediaType = .image,
        tab: MediaLibraryTab = .visual
    ) -> (BrowserModel, [MediaItem]) {
        let suite = "BrowserModelKeyboardSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flicksy-keyboard-selection-\(UUID().uuidString).sqlite")
        let model = BrowserModel(
            onboardingStore: OnboardingStore(defaults: defaults),
            libraryRepository: LibraryRepository(databaseURL: databaseURL)
        )
        model.sortKey = .name
        model.sortAscending = true
        model.replaceMediaItemsForTesting(makeItems(count: itemCount, type: type), tab: tab)
        return (model, model.orderedItems)
    }

    private func makeItems(
        count: Int,
        type: MediaType,
        namePrefix: String = "item"
    ) -> [MediaItem] {
        let fileExtension = switch type {
        case .audio: "mp3"
        case .video: "mov"
        case .image: "png"
        }
        return (0..<count).map { index in
            MediaItem(
                url: URL(fileURLWithPath: "/tmp/keyboard-\(namePrefix)-\(index).\(fileExtension)"),
                type: type,
                name: String(format: "\(namePrefix)-%02d.\(fileExtension)", index)
            )
        }
    }
}

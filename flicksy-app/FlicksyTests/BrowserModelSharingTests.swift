import XCTest
@testable import Flicksy

@MainActor
final class BrowserModelSharingTests: XCTestCase {
    func testEmptyAndSingleSelection() {
        let (model, items) = makeModel()
        XCTAssertFalse(model.canShare)
        XCTAssertTrue(model.shareURLs().isEmpty)
        model.selectItem(items[0])
        XCTAssertTrue(model.canShare)
        XCTAssertEqual(model.shareURLs(), [items[0].url])
    }

    func testMultipleMixedFilesKeepBrowserOrderAndSnapshot() {
        let (model, items) = makeModel()
        model.selectedItemIDs = Set(items.map(\.id))
        let urls = model.shareURLs()
        model.selectItem(items[2])
        XCTAssertEqual(urls, items.map(\.url))
    }

    func testContextClickInsideAndOutsideSelection() {
        let (model, items) = makeModel()
        model.selectedItemIDs = [items[0].id, items[1].id]
        XCTAssertEqual(model.shareURLs(clicked: items[1]), [items[0].url, items[1].url])
        XCTAssertEqual(model.shareURLs(clicked: items[2]), [items[2].url])
        XCTAssertEqual(model.selectedItemIDs, [items[2].id])
    }

    func testPreviewTakesPrecedenceOverBrowserSelection() {
        let (model, items) = makeModel()
        model.selectedItemIDs = Set(items.map(\.id))
        model.openViewer(items[0])
        XCTAssertEqual(model.shareURLs(), [items[0].url])
    }

    func testClipboardSharesOriginalFileURL() {
        let (model, items) = makeModel()
        model.selectedSource = .clipboard
        model.selectItem(items[0])
        XCTAssertEqual(model.shareURLs(), [items[0].url])
    }

    func testWindowsHaveIndependentTargetsAndPresenters() {
        let (first, firstItems) = makeModel()
        let (second, secondItems) = makeModel()
        first.selectItem(firstItems[0])
        second.selectItem(secondItems[2])
        XCTAssertFalse(first.sharingPresenter === second.sharingPresenter)
        XCTAssertEqual(first.shareURLs(), [firstItems[0].url])
        XCTAssertEqual(second.shareURLs(), [secondItems[2].url])
    }

    private func makeModel() -> (BrowserModel, [MediaItem]) {
        let suite = "BrowserModelSharingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suite).sqlite")
        let model = BrowserModel(
            onboardingStore: OnboardingStore(defaults: defaults),
            libraryRepository: LibraryRepository(databaseURL: databaseURL)
        )
        model.sortKey = .name
        model.sortAscending = true
        let items = zip(["a.png", "b.mov", "c.mp3"], [MediaType.image, .video, .audio]).map { name, type in
            MediaItem(url: URL(fileURLWithPath: "/tmp/\(name)"), type: type, name: name)
        }
        model.replaceMediaItemsForTesting(items, tab: .all)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return (model, model.orderedItems)
    }
}

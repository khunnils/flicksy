//
//  CommandPaletteSearchIndexTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

final class CommandPaletteSearchIndexTests: XCTestCase {
    func testIndexPreservesEveryVirtualLocationAndDeduplicatesPhysicalLocation() {
        let directory = URL(fileURLWithPath: "/tmp/FlicksyPaletteDownloads", isDirectory: true)
        let url = directory.appending(path: "hero.png")
        let tag = LibraryTag(id: UUID(), name: "Campaign", color: .blue, itemCount: 1)
        let collection = MediaCollection(id: UUID(), name: "Launch", itemCount: 1)
        let item = MediaItem(
            libraryID: UUID(),
            isFavorite: true,
            url: url,
            type: .image,
            name: "hero.png",
            tags: [tag]
        )
        let transientDuplicate = MediaItem(url: url, type: .image, name: "hero.png")

        let index = BrowserModel.makeCommandPaletteSearchIndex(
            destinations: [],
            libraryRecords: [LibrarySearchRecord(item: item, collections: [collection])],
            standardItems: [(.downloads, directory, [transientDuplicate])]
        )

        XCTAssertEqual(index.files.count, 4)
        XCTAssertEqual(Set(index.files.map(\.source)), [
            .standardFolder(.downloads),
            .favorites,
            .tag(tag.id),
            .collection(collection.id),
        ])
        XCTAssertEqual(index.files.filter { $0.source == .standardFolder(.downloads) }.count, 1)
        XCTAssertTrue(index.files.allSatisfy { $0.item.libraryID == item.libraryID })
    }

    func testFileMatchingRanksNameBeforeLocationAndPath() {
        let item = MediaItem(
            url: URL(fileURLWithPath: "/Media/Café/hero-shot.png"),
            type: .image,
            name: "hero-shot.png"
        )
        let location = CommandPaletteFileLocation(
            item: item,
            source: .folder("/Media/Café"),
            locationTitle: "Café",
            locationKind: "Folder"
        )

        XCTAssertEqual(location.matchRank(for: "HERO-SHOT.PNG"), 0)
        XCTAssertEqual(location.matchRank(for: "hero"), 1)
        XCTAssertEqual(location.matchRank(for: "shot"), 2)
        XCTAssertEqual(location.matchRank(for: "cafe"), 3)
        XCTAssertNil(location.matchRank(for: "missing"))
    }

    func testContextualCommandCapabilitiesRespectSelectionShapeAndSource() {
        let libraryID = UUID()
        let image = MediaItem(
            libraryID: libraryID,
            url: URL(fileURLWithPath: "/Media/hero.png"),
            type: .image,
            name: "hero.png"
        )
        let audio = MediaItem(
            libraryID: UUID(),
            url: URL(fileURLWithPath: "/Media/theme.mp3"),
            type: .audio,
            name: "theme.mp3"
        )

        let single = CommandPaletteSelectionCapabilities(
            items: [image],
            isClipboardSelected: false,
            isCollectionSelected: true
        )
        XCTAssertTrue(single.canOpenSelection)
        XCTAssertTrue(single.canGetInfo)
        XCTAssertTrue(single.canOrganize)
        XCTAssertTrue(single.canRename)
        XCTAssertTrue(single.canRemoveFromCollection)
        XCTAssertFalse(single.canEditMetaTags)

        let multiple = CommandPaletteSelectionCapabilities(
            items: [audio, MediaItem(
                libraryID: UUID(),
                url: URL(fileURLWithPath: "/Media/alternate.mp3"),
                type: .audio,
                name: "alternate.mp3"
            )],
            isClipboardSelected: false,
            isCollectionSelected: false
        )
        XCTAssertTrue(multiple.canOpenSelection)
        XCTAssertFalse(multiple.canGetInfo)
        XCTAssertFalse(multiple.canRename)
        XCTAssertTrue(multiple.canEditMetaTags)
        XCTAssertTrue(multiple.canOrganize)

        let mixed = CommandPaletteSelectionCapabilities(
            items: [image, MediaItem(
                url: URL(fileURLWithPath: "/Downloads/transient.png"),
                type: .image,
                name: "transient.png"
            )],
            isClipboardSelected: false,
            isCollectionSelected: true
        )
        XCTAssertFalse(mixed.canOrganize)
        XCTAssertFalse(mixed.canRemoveFromCollection)

        let clipboard = CommandPaletteSelectionCapabilities(
            items: [image],
            isClipboardSelected: true,
            isCollectionSelected: false
        )
        XCTAssertFalse(clipboard.canDuplicate)
        XCTAssertFalse(clipboard.canRename)

        let empty = CommandPaletteSelectionCapabilities(
            items: [],
            isClipboardSelected: false,
            isCollectionSelected: false
        )
        XCTAssertFalse(empty.canOpenSelection)
    }

    func testPendingFileResolutionUsesLibraryIDThenStandardizedURLFallback() {
        let libraryID = UUID()
        let indexed = MediaItem(
            libraryID: libraryID,
            url: URL(fileURLWithPath: "/Media/hero.png"),
            type: .image,
            name: "hero.png"
        )
        let pending = CommandPaletteFileLocation(
            item: indexed,
            source: .folder("/Media"),
            locationTitle: "Media",
            locationKind: "Folder"
        )

        let moved = MediaItem(
            libraryID: libraryID,
            url: URL(fileURLWithPath: "/Media/renamed.png"),
            type: .image,
            name: "renamed.png"
        )
        XCTAssertEqual(
            BrowserModel.resolveCommandPaletteItem(pending, in: [moved])?.id,
            moved.id
        )

        let transient = MediaItem(
            url: URL(fileURLWithPath: "/Media/./hero.png"),
            type: .image,
            name: "hero.png"
        )
        XCTAssertEqual(
            BrowserModel.resolveCommandPaletteItem(pending, in: [transient])?.url.standardizedFileURL,
            indexed.url.standardizedFileURL
        )
        XCTAssertNil(BrowserModel.resolveCommandPaletteItem(pending, in: []))
    }
}

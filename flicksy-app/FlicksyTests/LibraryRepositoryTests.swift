//
//  LibraryRepositoryTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

final class LibraryRepositoryTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
    }

    // MARK: - Helpers

    private func makeRepository() -> LibraryRepository {
        let dbURL = workspace
            .appending(path: "db-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "library.sqlite3", directoryHint: .notDirectory)
        return LibraryRepository(databaseURL: dbURL)
    }

    @discardableResult
    private func writeFile(_ relativePath: String, in root: URL, bytes: Int = 8) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(repeating: 0xAB, count: bytes)
        try data.write(to: url)
        return url
    }

    private func makeRoot(_ name: String = "root") throws -> URL {
        let root = workspace.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Indexing

    func testRecursiveIndexSkipsExcludedDirectories() async throws {
        let repo = makeRepository()
        let root = try makeRoot()
        try writeFile("Photos/shot.png", in: root)
        try writeFile("node_modules/dep.png", in: root)
        try writeFile("Dummy.app/Contents/Resources/icon.png", in: root)
        try writeFile(".secret/hidden.png", in: root)
        try writeFile("venv/clip.mov", in: root)

        let photos = root.appending(path: "Photos", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "Alias", directoryHint: .isDirectory),
            withDestinationURL: photos
        )

        try await repo.reconcile(roots: [root])
        let all = try await repo.query(.all)
        XCTAssertEqual(Set(all.items.map(\.name)), ["shot.png"])
    }

    func testRecursiveIndexRespectsCustomPolicy() async throws {
        let repo = makeRepository()
        let root = try makeRoot()
        try writeFile("node_modules/dep.png", in: root)

        var policy = FolderScanPolicy.default
        policy.excludedDirectoryNames.remove("node_modules")

        try await repo.reconcile(roots: [root], policy: policy)
        let all = try await repo.query(.all)
        XCTAssertEqual(all.items.map(\.name), ["dep.png"])
    }

    func testRecursiveIndexAcrossRoots() async throws {
        let repo = makeRepository()
        let rootA = try makeRoot("A")
        let rootB = try makeRoot("B")
        try writeFile("top.png", in: rootA)
        try writeFile("nested/deep/clip.mov", in: rootA)
        try writeFile("song.mp3", in: rootB)
        try writeFile("notes.txt", in: rootA) // ignored, not media

        try await repo.reconcile(roots: [rootA, rootB])

        let all = try await repo.query(.all)
        XCTAssertEqual(Set(all.items.map(\.name)), ["top.png", "clip.mov", "song.mp3"])
    }

    func testRemovingRootHidesItsAssets() async throws {
        let repo = makeRepository()
        let rootA = try makeRoot("A")
        let rootB = try makeRoot("B")
        try writeFile("a.png", in: rootA)
        try writeFile("b.png", in: rootB)

        try await repo.reconcile(roots: [rootA, rootB])
        let initialCount = try await repo.query(.all).items.count
        XCTAssertEqual(initialCount, 2)

        // Root A removed from the authorized set: its assets must stop appearing.
        try await repo.reconcile(roots: [rootB])
        let names = try await repo.query(.all).items.map(\.name)
        XCTAssertEqual(names, ["b.png"])
    }

    // MARK: - Tags

    func testTagCaseInsensitiveUniqueness() async throws {
        let repo = makeRepository()
        _ = try await repo.createTag(name: "Blue", color: .blue)
        do {
            _ = try await repo.createTag(name: "  blue ", color: .red)
            XCTFail("Expected duplicate name to be rejected")
        } catch let error as LibraryRepository.RepositoryError {
            guard case .duplicateName = error else {
                return XCTFail("Expected duplicateName, got \(error)")
            }
        }
    }

    func testTagRenameMergeCombinesMemberships() async throws {
        let repo = makeRepository()
        let root = try makeRoot()
        try writeFile("one.png", in: root)
        try writeFile("two.png", in: root)
        try await repo.reconcile(roots: [root])
        let items = try await repo.query(.all).items
        let ids = items.compactMap(\.libraryID)

        let keep = try await repo.createTag(name: "Keep", color: .green)
        let drop = try await repo.createTag(name: "Drop", color: .red)
        try await repo.setTag(keep.id, on: [ids[0]], enabled: true)
        try await repo.setTag(drop.id, on: [ids[1]], enabled: true)

        // Renaming Drop onto Keep without merge is a conflict.
        do {
            try await repo.updateTag(id: drop.id, name: "Keep", color: .red, mergeOnConflict: false)
            XCTFail("Expected conflict")
        } catch let error as LibraryRepository.RepositoryError {
            guard case .duplicateName = error else { return XCTFail("Expected duplicateName") }
        }

        try await repo.updateTag(id: drop.id, name: "Keep", color: .green, mergeOnConflict: true)

        let tags = try await repo.tags()
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags.first?.name, "Keep")
        XCTAssertEqual(tags.first?.itemCount, 2)
    }

    func testTagRecolorKeepsSameTag() async throws {
        let repo = makeRepository()
        let tag = try await repo.createTag(name: "Warm", color: .orange)
        try await repo.updateTag(id: tag.id, name: "Warm", color: .red, mergeOnConflict: false)
        let tags = try await repo.tags()
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags.first?.color, .red)
    }

    func testQueryHydratesTags() async throws {
        let repo = makeRepository()
        let root = try makeRoot()
        try writeFile("photo.png", in: root)
        try await repo.reconcile(roots: [root])
        let id = try await repo.query(.all).items.first!.libraryID!
        let tag = try await repo.createTag(name: "Hero", color: .purple)
        try await repo.setTag(tag.id, on: [id], enabled: true)

        let item = try await repo.query(.all).items.first!
        XCTAssertEqual(item.tags.map(\.name), ["Hero"])
    }

    // MARK: - Favorites

    func testFavoritePersistsAcrossReopen() async throws {
        let dbURL = workspace
            .appending(path: "persist", directoryHint: .isDirectory)
            .appending(path: "library.sqlite3", directoryHint: .notDirectory)
        let root = try makeRoot()
        try writeFile("keep.png", in: root)

        do {
            let repo = LibraryRepository(databaseURL: dbURL)
            try await repo.reconcile(roots: [root])
            let id = try await repo.query(.all).items.first!.libraryID!
            try await repo.setFavorite(true, assetIDs: [id])
        }

        let reopened = LibraryRepository(databaseURL: dbURL)
        try await reopened.reconcile(roots: [root])
        let favorites = try await reopened.query(.favorites).items
        XCTAssertEqual(favorites.map(\.name), ["keep.png"])
        XCTAssertTrue(favorites.first?.isFavorite ?? false)
    }

    // MARK: - Collections

    func testCollectionAddIgnoresDuplicatesAndPreservesOrder() async throws {
        let repo = makeRepository()
        let root = try makeRoot()
        try writeFile("1.png", in: root)
        try writeFile("2.png", in: root)
        try writeFile("3.png", in: root)
        try await repo.reconcile(roots: [root])

        // Assets sorted by name so order is deterministic for the test.
        let ids = try await repo.query(.all).items.sorted { $0.name < $1.name }.compactMap(\.libraryID)
        let collection = try await repo.createCollection(name: "Reel")
        try await repo.add(assetIDs: [ids[2], ids[0]], to: collection.id)
        try await repo.add(assetIDs: [ids[0], ids[1]], to: collection.id) // ids[0] duplicate

        let ordered = try await repo.query(.collection(collection.id)).items.compactMap(\.libraryID)
        XCTAssertEqual(ordered, [ids[2], ids[0], ids[1]])
    }

    func testRemovingFromCollectionKeepsAsset() async throws {
        let repo = makeRepository()
        let root = try makeRoot()
        try writeFile("a.png", in: root)
        try await repo.reconcile(roots: [root])
        let id = try await repo.query(.all).items.first!.libraryID!
        let collection = try await repo.createCollection(name: "C")
        try await repo.add(assetIDs: [id], to: collection.id)

        try await repo.remove(assetIDs: [id], from: collection.id)

        let remaining = try await repo.query(.collection(collection.id)).items
        XCTAssertTrue(remaining.isEmpty)
        let assetCount = try await repo.query(.all).items.count
        XCTAssertEqual(assetCount, 1) // asset row still exists
    }

    func testReorderWritesManualOrder() async throws {
        let repo = makeRepository()
        let root = try makeRoot()
        try writeFile("1.png", in: root)
        try writeFile("2.png", in: root)
        try await repo.reconcile(roots: [root])
        let ids = try await repo.query(.all).items.sorted { $0.name < $1.name }.compactMap(\.libraryID)
        let collection = try await repo.createCollection(name: "C")
        try await repo.add(assetIDs: ids, to: collection.id)

        try await repo.reorder(collectionID: collection.id, assetID: ids[1], before: ids[0])
        let ordered = try await repo.query(.collection(collection.id)).items.compactMap(\.libraryID)
        XCTAssertEqual(ordered, [ids[1], ids[0]])
    }

    // MARK: - Identity reconciliation

    func testRenameWithinRootKeepsIdentityAndOrganization() async throws {
        let repo = makeRepository()
        let root = try makeRoot()
        let original = try writeFile("before.png", in: root)
        try await repo.reconcile(roots: [root])
        let id = try await repo.query(.all).items.first!.libraryID!

        let tag = try await repo.createTag(name: "Pick", color: .yellow)
        try await repo.setTag(tag.id, on: [id], enabled: true)
        let collection = try await repo.createCollection(name: "C")
        try await repo.add(assetIDs: [id], to: collection.id)

        // Rename on disk keeps the same inode, so identity should be preserved.
        let renamed = root.appending(path: "after.png")
        try FileManager.default.moveItem(at: original, to: renamed)
        try await repo.reconcile(roots: [root])

        let item = try await repo.query(.all).items.first!
        XCTAssertEqual(item.libraryID, id)
        XCTAssertEqual(item.name, "after.png")
        XCTAssertEqual(item.tags.map(\.name), ["Pick"])
        let inCollection = try await repo.query(.collection(collection.id)).items.compactMap(\.libraryID)
        XCTAssertEqual(inCollection, [id])
    }

    func testMissingThenRestoredKeepsCollectionPosition() async throws {
        let repo = makeRepository()
        let root = try makeRoot()
        let file = try writeFile("clip.mov", in: root)
        try await repo.reconcile(roots: [root])
        let id = try await repo.query(.all).items.first!.libraryID!
        let collection = try await repo.createCollection(name: "C")
        try await repo.add(assetIDs: [id], to: collection.id)

        // File goes missing.
        try FileManager.default.removeItem(at: file)
        try await repo.reconcile(roots: [root])
        let afterLoss = try await repo.query(.collection(collection.id))
        XCTAssertTrue(afterLoss.items.isEmpty)
        XCTAssertEqual(afterLoss.missingItems.map(\.assetID), [id])

        // File restored at the same path.
        try writeFile("clip.mov", in: root)
        try await repo.reconcile(roots: [root])
        let restored = try await repo.query(.collection(collection.id))
        XCTAssertEqual(restored.items.compactMap(\.libraryID), [id])
        XCTAssertTrue(restored.missingItems.isEmpty)
    }

    // MARK: - Outside-root rejection

    func testAssetIDsRejectsFilesOutsideRoots() async throws {
        let repo = makeRepository()
        let root = try makeRoot()
        try writeFile("inside.png", in: root)
        try await repo.reconcile(roots: [root])
        let outside = try writeFile("outside.png", in: workspace)

        do {
            _ = try await repo.assetIDs(for: [outside], roots: [root])
            XCTFail("Expected outsideLibrary rejection")
        } catch let error as LibraryRepository.RepositoryError {
            guard case .outsideLibrary = error else { return XCTFail("Expected outsideLibrary") }
        }
    }

    func testRelinkRejectsFileOutsideRoots() async throws {
        let repo = makeRepository()
        let root = try makeRoot()
        let file = try writeFile("clip.mov", in: root)
        try await repo.reconcile(roots: [root])
        let id = try await repo.query(.all).items.first!.libraryID!
        try FileManager.default.removeItem(at: file)
        let outside = try writeFile("elsewhere.mov", in: workspace)

        do {
            try await repo.relink(assetID: id, to: outside, roots: [root])
            XCTFail("Expected outsideLibrary rejection")
        } catch let error as LibraryRepository.RepositoryError {
            guard case .outsideLibrary = error else { return XCTFail("Expected outsideLibrary") }
        }
    }
}

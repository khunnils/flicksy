//
//  FolderScannerTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

final class FolderScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyScan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ relativePath: String) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xCD, count: 4).write(to: url)
    }

    /// The folder browser must show only the direct contents of the selected
    /// folder even though the catalog indexes recursively.
    func testScannerReturnsOnlyDirectChildren() async throws {
        try write("direct.png")
        try write("clip.mov")
        try write("sub/nested.png")
        try write("sub/deeper/buried.mp3")

        let items = try await FolderScanner.mediaItems(in: root)
        XCTAssertEqual(Set(items.map(\.name)), ["direct.png", "clip.mov"])
    }

    func testTreeSkipsExcludedHiddenPackagedAndSymlinkedDirectories() async throws {
        try write("Photos/shot.png")
        try write("node_modules/dep.png")
        try write("Dummy.app/Contents/Resources/icon.png")
        try write(".secret/hidden.png")

        let photos = root.appending(path: "Photos", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "Alias", directoryHint: .isDirectory),
            withDestinationURL: photos
        )

        let tree = try await FolderScanner.buildTree(for: root)
        XCTAssertEqual(Set(tree.children.map(\.name)), ["Photos"])
        XCTAssertEqual(tree.children.first?.children.map(\.name) ?? [], [])
    }

    func testTreeEntersExcludedNameWhenItIsTheScanRoot() async throws {
        let nested = root.appending(path: "node_modules", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("node_modules/Photos/shot.png")
        try write("node_modules/.git/ignored.png")

        let tree = try await FolderScanner.buildTree(for: nested)
        XCTAssertEqual(tree.name, "node_modules")
        XCTAssertEqual(Set(tree.children.map(\.name)), ["Photos"])
    }

    func testCustomPolicyCanScanAnOtherwiseExcludedDirectory() async throws {
        try write("node_modules/dep.png")
        try write("Photos/shot.png")

        var policy = FolderScanPolicy.default
        policy.excludedDirectoryNames.remove("node_modules")

        let tree = try await FolderScanner.buildTree(for: root, policy: policy)
        XCTAssertEqual(Set(tree.children.map(\.name)), ["Photos", "node_modules"])
    }
}

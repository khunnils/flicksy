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
}

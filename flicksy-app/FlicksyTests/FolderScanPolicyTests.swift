//
//  FolderScanPolicyTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

final class FolderScanPolicyTests: XCTestCase {
    func testBuiltInNamesCoverTheDocumentedCategories() {
        let names = FolderScanPolicy.builtInExcludedDirectoryNames
        XCTAssertTrue(names.contains("node_modules"))
        XCTAssertTrue(names.contains(".git"))
        XCTAssertTrue(names.contains("DerivedData"))
        XCTAssertTrue(names.contains("venv"))
        XCTAssertTrue(names.contains(".venv"))
        XCTAssertTrue(names.contains("__MACOSX"))
        XCTAssertTrue(names.contains("Library"))
        XCTAssertTrue(FolderScanPolicy.builtInNamesByGroup.keys.count == FolderScanExclusionGroup.allCases.count)
    }

    func testNameExclusionsAreCaseInsensitive() {
        let policy = FolderScanPolicy.default
        XCTAssertTrue(policy.excludesDirectoryName("node_modules"))
        XCTAssertTrue(policy.excludesDirectoryName("Node_Modules"))
        XCTAssertTrue(policy.excludesDirectoryName("DERIVEDDATA"))
        XCTAssertFalse(policy.excludesDirectoryName("Photos"))
    }

    func testShouldDescendRejectsExcludedNamesWithoutResourceValues() {
        let policy = FolderScanPolicy.default
        let url = URL(fileURLWithPath: "/tmp/project/node_modules", isDirectory: true)
        XCTAssertFalse(policy.shouldDescend(into: url, values: nil))
    }

    func testShouldDescendAllowsUnknownNamesWhenValuesAreMissing() {
        let policy = FolderScanPolicy.default
        let url = URL(fileURLWithPath: "/tmp/project/Photos", isDirectory: true)
        XCTAssertTrue(policy.shouldDescend(into: url, values: nil))
    }

    func testDefaultListingOptionsSkipHiddenFilesAndPackages() {
        let options = FolderScanPolicy.default.directoryEnumerationOptions
        XCTAssertTrue(options.contains(.skipsHiddenFiles))
        XCTAssertTrue(options.contains(.skipsPackageDescendants))
    }

    func testPolicyCanDisableHiddenAndPackageListingFilters() {
        var policy = FolderScanPolicy.default
        policy.skipHiddenDirectories = false
        policy.skipPackages = false
        XCTAssertTrue(policy.directoryEnumerationOptions.isEmpty)
    }

    func testWalkerNeverListsAnExcludedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyPolicy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keep = root.appending(path: "Photos/shot.png")
        let skip = root.appending(path: "node_modules/dep.png")
        for url in [keep, skip] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0xAB, count: 4).write(to: url)
        }

        var visited: [String] = []
        try FolderScanWalker.forEachRegularFile(in: root, keys: [.isRegularFileKey]) { url, _ in
            visited.append(url.lastPathComponent)
        }
        XCTAssertEqual(visited, ["shot.png"])
    }
}

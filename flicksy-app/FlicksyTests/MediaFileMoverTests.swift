//
//  MediaFileMoverTests.swift
//  FlicksyTests
//

import XCTest
@testable import Flicksy

final class MediaFileMoverTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "FlicksyMove-\(UUID().uuidString)", directoryHint: .isDirectory)
        source = root.appending(path: "Source", directoryHint: .isDirectory)
        destination = root.appending(path: "Destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testMovesMultipleFilesWithoutRenaming() throws {
        let first = try write("one.png", in: source)
        let second = try write("two.mp4", in: source)

        let result = MediaFileMover.move([first, second], into: destination)

        XCTAssertEqual(Set(result.movedNames), ["one.png", "two.mp4"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "one.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "two.mp4").path))
    }

    func testCollisionDoesNotReplaceExistingFileAndOtherFilesStillMove() throws {
        let conflicting = try write("same.png", in: source, byte: 0x11)
        let movable = try write("move.png", in: source, byte: 0x22)
        let existing = try write("same.png", in: destination, byte: 0x33)

        let result = MediaFileMover.move([conflicting, movable], into: destination)

        XCTAssertEqual(result.conflictingNames, ["same.png"])
        XCTAssertEqual(result.movedNames, ["move.png"])
        XCTAssertEqual(try Data(contentsOf: existing), Data([0x33]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflicting.path))
    }

    func testDroppingIntoCurrentFolderIsUnchanged() throws {
        let file = try write("still-here.wav", in: source)

        let result = MediaFileMover.move([file], into: source)

        XCTAssertEqual(result.unchangedNames, ["still-here.wav"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    private func write(_ name: String, in directory: URL, byte: UInt8 = 0xAB) throws -> URL {
        let url = directory.appending(path: name)
        try Data([byte]).write(to: url)
        return url
    }
}

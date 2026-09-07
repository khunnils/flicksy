import XCTest
import SQLite3
@testable import Flicksy

final class SmartCollectionTests: XCTestCase {
    private var workspace: URL!
    private var databaseURL: URL { workspace.appendingPathComponent("library.sqlite3") }
    private var now: Date { Date(timeIntervalSinceReferenceDate: 800_000_000) }

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("SmartCollections-\(UUID())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: workspace) }

    private func file(_ name: String, bytes: Int = 8, modified: Date? = nil) throws -> URL {
        let url = workspace.appendingPathComponent("root").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified ?? now], ofItemAtPath: url.path)
        return url
    }
    private var root: URL { workspace.appendingPathComponent("root") }
    private func repository() async throws -> LibraryRepository {
        let repo = LibraryRepository(databaseURL: databaseURL)
        try await repo.reconcile(roots: [root])
        return repo
    }
    private func rule(_ field: SmartCollectionRule.Field, _ condition: SmartCollectionRule.Condition,
                      text: String = "", number: Double = 100, tag: UUID? = nil,
                      kind: SmartCollectionRule.Kind = .image) -> SmartCollectionRule {
        SmartCollectionRule(field: field, condition: condition, text: text, number: number, kind: kind, tagID: tag)
    }
    private func names(_ repo: LibraryRepository, _ rules: [SmartCollectionRule],
                       match: SmartCollectionDefinition.Match = .all, scope: String? = nil,
                       time: Date? = nil) async throws -> [String] {
        let definition = SmartCollectionDefinition(rootPath: scope, match: match, rules: rules)
        let result = try await repo.query(.smartCollection(definition, rootPaths: [root.path], now: time ?? now))
        let count = try await repo.smartCollectionCount(definition, rootPaths: [root.path], now: time ?? now)
        XCTAssertEqual(result.items.count, count, "Preview and listing must agree")
        XCTAssertTrue(result.missingItems.isEmpty)
        return result.items.map(\.name).sorted()
    }
    private func sql(_ text: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, text, nil, nil, nil), SQLITE_OK)
    }

    func testAllAnyAndLiteralUnicodeFilenameMatching() async throws {
        try file("CAFÉ_100%.png", bytes: 20)
        try file("other.png", bytes: 5)
        try file("movie.mov", bytes: 30)
        let repo = try await repository()
        let filename = rule(.filename, .contains, text: "café_100%")
        let size = rule(.fileSize, .greaterThan, number: 0.000025)
        let literal = try await names(repo, [filename])
        XCTAssertEqual(literal, ["CAFÉ_100%.png"])
        let all = try await names(repo, [filename, size])
        XCTAssertEqual(all, [])
        let any = try await names(repo, [filename, size], match: .any)
        XCTAssertEqual(any, ["CAFÉ_100%.png", "movie.mov"])
        let notContains = try await names(repo, [rule(.filename, .doesNotContain, text: "%")])
        XCTAssertEqual(notContains, ["movie.mov", "other.png"])
        let injected = try await names(repo, [rule(.filename, .contains, text: "' OR 1=1 --")])
        XCTAssertEqual(injected, [])
    }

    func testSizeBoundariesUnitsAndMissingMetadata() async throws {
        try file("small.png", bytes: 9)
        try file("equal.png", bytes: 10)
        try file("large.png", bytes: 11)
        try file("unknown.png", bytes: 20)
        let repo = try await repository()
        try sql("UPDATE assets SET file_size = NULL WHERE name = 'unknown.png'")
        let less = try await names(repo, [rule(.fileSize, .lessThan, number: 0.00001)])
        let greater = try await names(repo, [rule(.fileSize, .greaterThan, number: 0.00001)])
        XCTAssertEqual(less, ["small.png"])
        XCTAssertEqual(greater, ["large.png"])
        var gb = rule(.fileSize, .greaterThan, number: 0.00000001)
        gb.unit = .gb
        let gigabytes = try await names(repo, [gb])
        XCTAssertEqual(gigabytes, greater)
    }

    func testRollingDateBoundariesAndClockAdvance() async throws {
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        try file("boundary.png", modified: cutoff)
        try file("older.png", modified: cutoff.addingTimeInterval(-1))
        try file("now.png")
        try file("future.png", modified: now.addingTimeInterval(1))
        try file("unknown.png")
        let repo = try await repository()
        try sql("UPDATE assets SET modified_at = NULL WHERE name = 'unknown.png'")
        let recent = rule(.modifiedDate, .withinDays, number: 7)
        let results = try await names(repo, [recent])
        XCTAssertEqual(results, ["boundary.png", "now.png"])
        let older = try await names(repo, [rule(.modifiedDate, .olderThanDays, number: 7)])
        XCTAssertEqual(older, ["older.png"])
        let advanced = try await names(repo, [recent], time: now.addingTimeInterval(2))
        XCTAssertEqual(advanced, ["future.png", "now.png"])
    }

    func testTagFavoriteAndKindMembershipChanges() async throws {
        try file("photo.png")
        try file("clip.mov")
        let repo = try await repository()
        let items = try await repo.query(.all).items
        let photoID = try XCTUnwrap(items.first { $0.name == "photo.png" }?.libraryID)
        let tag = try await repo.createTag(name: "Work", color: .blue)
        try await repo.setTag(tag.id, on: [photoID], enabled: true)
        try await repo.setFavorite(true, assetIDs: [photoID])
        let tagged = try await names(repo, [rule(.tag, .hasTag, tag: tag.id), rule(.favorite, .isValue)])
        XCTAssertEqual(tagged, ["photo.png"])
        let untagged = try await names(repo, [rule(.tag, .hasNoTags)])
        let without = try await names(repo, [rule(.tag, .doesNotHaveTag, tag: tag.id)])
        XCTAssertEqual(untagged, ["clip.mov"])
        XCTAssertEqual(without, untagged)
        let videos = try await names(repo, [rule(.mediaType, .isValue, kind: .video)])
        let nonImages = try await names(repo, [rule(.mediaType, .isNot, kind: .image), rule(.favorite, .isNot)])
        XCTAssertEqual(videos, ["clip.mov"])
        XCTAssertEqual(nonImages, videos)
        try await repo.setTag(tag.id, on: [photoID], enabled: false)
        try await repo.setFavorite(false, assetIDs: [photoID])
        let updated = try await names(repo, [rule(.tag, .hasNoTags), rule(.favorite, .isNot)])
        XCTAssertEqual(updated, ["clip.mov", "photo.png"])
    }

    func testScopeRecursesAndRemovedReferencesRequireRepair() async throws {
        try file("nested/photo.png")
        let repo = try await repository()
        let scoped = SmartCollectionDefinition(rootPath: root.path, rules: [rule(.tag, .hasNoTags)])
        let result = try await names(repo, scoped.rules, scope: root.path)
        XCTAssertEqual(result, ["photo.png"])
        let tag = try await repo.createTag(name: "Temporary", color: .red)
        let tagged = SmartCollectionDefinition(match: .any, rules: [rule(.tag, .doesNotHaveTag, tag: tag.id), rule(.tag, .hasNoTags)])
        try await repo.saveSmartCollection(name: "Scoped", definition: scoped, rootPaths: [root.path])
        try await repo.saveSmartCollection(name: "Tagged", definition: tagged, rootPaths: [root.path])
        try await repo.deleteTag(id: tag.id)
        let saved = try await repo.smartCollections(rootPaths: [])
        XCTAssertTrue(saved.allSatisfy { $0.repairMessage != nil && $0.itemCount == 0 })
        do {
            _ = try await repo.query(.smartCollection(tagged, rootPaths: [root.path], now: now))
            XCTFail("Missing reference must invalidate the whole OR expression")
        } catch SmartCollectionError.missingTag {}
        try await repo.reconcile(roots: [])
        let unavailable = try await names(repo, [rule(.tag, .hasNoTags)])
        XCTAssertTrue(unavailable.isEmpty)
    }

    func testPersistenceMigrationUniquenessAndDefinitionDeletionPreserveOrganization() async throws {
        try file("photo.png")
        let repo = try await repository()
        let assets = try await repo.query(.all).items
        let assetID = try XCTUnwrap(assets.first?.libraryID)
        let tag = try await repo.createTag(name: "Keep", color: .green)
        let manual = try await repo.createCollection(name: "Manual")
        try await repo.setTag(tag.id, on: [assetID], enabled: true)
        try await repo.add(assetIDs: [assetID], to: manual.id)
        // The pre-feature schema has these exact organization tables and no smart table.
        try sql("DROP TABLE smart_collections; PRAGMA user_version = 1;")
        let migrated = LibraryRepository(databaseURL: databaseURL)
        let definition = SmartCollectionTemplate.large.definition
        let id = try await migrated.saveSmartCollection(name: " Large ", definition: definition, rootPaths: [root.path])
        do {
            try await migrated.saveSmartCollection(name: "large", definition: definition, rootPaths: [root.path])
            XCTFail("Names must be unique using the existing normalization")
        } catch LibraryRepository.RepositoryError.duplicateName {}
        let reopened = LibraryRepository(databaseURL: databaseURL)
        let saved = try await reopened.smartCollections(rootPaths: [root.path])
        XCTAssertEqual(saved.first?.definition, definition)
        XCTAssertEqual(saved.first?.name, "Large")
        try await reopened.saveSmartCollection(id: id, name: "Renamed", definition: SmartCollectionTemplate.untagged.definition, rootPaths: [root.path])
        let renamed = try await reopened.smartCollections(rootPaths: [root.path])
        XCTAssertEqual(renamed.count, 1)
        XCTAssertEqual(renamed.first?.name, "Renamed")
        try await reopened.deleteSmartCollection(id: id)
        let deleted = try await reopened.smartCollections(rootPaths: [root.path])
        XCTAssertTrue(deleted.isEmpty)
        let retained = try await reopened.query(.collection(manual.id))
        XCTAssertEqual(retained.items.first?.libraryID, assetID)
        XCTAssertEqual(retained.items.first?.tags.map(\.id), [tag.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("photo.png").path))
    }

    func testInvalidAndUnreadableDefinitionsRemainRepairable() async throws {
        try file("photo.png")
        let repo = try await repository()
        let invalid = [SmartCollectionDefinition(rules: []), SmartCollectionDefinition(),
                       SmartCollectionDefinition(rules: [rule(.modifiedDate, .withinDays, number: -1)]),
                       SmartCollectionDefinition(rules: [rule(.fileSize, .contains, number: 1)])]
        for definition in invalid {
            do {
                _ = try await repo.smartCollectionCount(definition, rootPaths: [root.path])
                XCTFail("Invalid definition was accepted")
            } catch SmartCollectionError.invalidRules {}
        }
        try await repo.saveSmartCollection(name: "Broken", definition: SmartCollectionTemplate.untagged.definition, rootPaths: [root.path])
        try sql("UPDATE smart_collections SET definition = 'invalid json'")
        let saved = try await repo.smartCollections(rootPaths: [root.path])
        XCTAssertEqual(saved.count, 1)
        XCTAssertNotNil(saved[0].repairMessage)
        XCTAssertEqual(saved[0].itemCount, 0)
    }
}

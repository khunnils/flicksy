//
//  LibraryRepository.swift
//  Flicksy
//

import Foundation
import SQLite3
import UniformTypeIdentifiers

/// App-owned catalog for root-backed media and creator organization metadata.
/// All SQLite and recursive filesystem work is actor isolated and never runs on
/// the main actor.
actor LibraryRepository {
    enum RepositoryError: LocalizedError {
        case database(String)
        case invalidName
        case duplicateName
        case outsideLibrary

        var errorDescription: String? {
            switch self {
            case .database(let message): message
            case .invalidName: "Enter a name that is not empty."
            case .duplicateName: "That name is already in use."
            case .outsideLibrary: "Only media inside an added folder can be organized."
            }
        }
    }

    private struct Candidate {
        let rootPath: String
        let relativePath: String
        let resourceID: String?
        let item: MediaItem
    }

    private var db: OpaquePointer?
    private let databaseURL: URL

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
        do {
            try FileManager.default.createDirectory(
                at: self.databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard sqlite3_open_v2(
                self.databaseURL.path,
                &db,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK else {
                return
            }
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try migrate()
        } catch {
            sqlite3_close(db)
            db = nil
        }
    }

    deinit { sqlite3_close(db) }

    func reconcile(roots: [URL], policy: FolderScanPolicy = .default) throws {
        try requireDatabase()
        let standardizedRoots = roots.map(\.standardizedFileURL)
        let candidates = try standardizedRoots.flatMap { try Self.candidates(in: $0, policy: policy) }

        try transaction {
            // Mark everything unavailable first so assets under removed roots stop
            // leaking into library views. Rows are re-marked available as their
            // files are rediscovered below; organization records are preserved
            // either way because only the `available` flag changes.
            try execute("UPDATE assets SET available = 0")
            for candidate in candidates {
                try upsert(candidate)
            }
        }
    }

    func query(_ query: LibraryQuery) throws -> LibraryQueryResult {
        try requireDatabase()
        var joins = ""
        var predicate = "a.available = 1"
        var order = "a.name COLLATE NOCASE, a.id"
        var argument: String?

        switch query {
        case .all:
            break
        case .favorites:
            predicate += " AND a.favorite = 1"
        case .tag(let id):
            joins = "JOIN asset_tags at ON at.asset_id = a.id"
            predicate += " AND at.tag_id = ?"
            argument = id.uuidString
        case .collection(let id):
            joins = "JOIN collection_items ci ON ci.asset_id = a.id"
            predicate += " AND ci.collection_id = ?"
            order = "ci.position, a.id"
            argument = id.uuidString
        }

        let statement = try prepare("""
            SELECT a.id, a.root_path, a.relative_path, a.name, a.media_type,
                   a.file_size, a.modified_at, a.added_at, a.favorite
            FROM assets a \(joins)
            WHERE \(predicate)
            ORDER BY \(order)
            """)
        defer { sqlite3_finalize(statement) }
        if let argument { bind(argument, to: 1, in: statement) }

        var items: [MediaItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0)),
                  let type = MediaType(databaseValue: Int(sqlite3_column_int(statement, 4)))
            else { continue }
            let root = URL(fileURLWithPath: text(statement, 1), isDirectory: true)
            let relative = text(statement, 2)
            let url = root.appending(path: relative)
            items.append(MediaItem(
                libraryID: id,
                isFavorite: sqlite3_column_int(statement, 8) != 0,
                url: url,
                type: type,
                name: text(statement, 3),
                fileSize: optionalInt64(statement, 5),
                modifiedAt: optionalDate(statement, 6),
                addedAt: optionalDate(statement, 7)
            ))
        }

        let tagsByAsset = try tagMap(for: items.compactMap(\.libraryID))
        items = items.map { item in
            guard let id = item.libraryID, let tags = tagsByAsset[id] else { return item }
            var hydrated = item
            hydrated.tags = tags
            return hydrated
        }

        var missing: [MissingCollectionItem] = []
        if case .collection(let collectionID) = query {
            let missingStatement = try prepare("""
                SELECT ci.id, a.id, a.name, a.root_path, a.relative_path
                FROM collection_items ci
                JOIN assets a ON a.id = ci.asset_id
                WHERE ci.collection_id = ? AND a.available = 0
                ORDER BY ci.position
                """)
            defer { sqlite3_finalize(missingStatement) }
            bind(collectionID.uuidString, to: 1, in: missingStatement)
            while sqlite3_step(missingStatement) == SQLITE_ROW {
                guard let membershipID = UUID(uuidString: text(missingStatement, 0)),
                      let assetID = UUID(uuidString: text(missingStatement, 1))
                else { continue }
                let path = URL(fileURLWithPath: text(missingStatement, 3), isDirectory: true)
                    .appending(path: text(missingStatement, 4)).path
                missing.append(MissingCollectionItem(
                    id: membershipID,
                    assetID: assetID,
                    name: text(missingStatement, 2),
                    lastKnownPath: path
                ))
            }
        }
        return LibraryQueryResult(items: items, missingItems: missing)
    }

    /// Hydrated assets and their virtual collection locations for global search.
    /// This intentionally reuses the catalog instead of walking root folders when
    /// the command palette opens.
    func searchRecords() throws -> [LibrarySearchRecord] {
        let items = try query(.all).items
        guard !items.isEmpty else { return [] }

        let statement = try prepare("""
            SELECT ci.asset_id, c.id, c.name,
                   (SELECT COUNT(*) FROM collection_items count_items
                    WHERE count_items.collection_id = c.id)
            FROM collection_items ci
            JOIN collections c ON c.id = ci.collection_id
            JOIN assets a ON a.id = ci.asset_id
            WHERE a.available = 1
            ORDER BY c.name COLLATE NOCASE
            """)
        defer { sqlite3_finalize(statement) }

        var collectionsByAsset: [UUID: [MediaCollection]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let assetID = UUID(uuidString: text(statement, 0)),
                  let collectionID = UUID(uuidString: text(statement, 1))
            else { continue }
            collectionsByAsset[assetID, default: []].append(MediaCollection(
                id: collectionID,
                name: text(statement, 2),
                itemCount: Int(sqlite3_column_int64(statement, 3))
            ))
        }

        return items.map { item in
            LibrarySearchRecord(
                item: item,
                collections: item.libraryID.flatMap { collectionsByAsset[$0] } ?? []
            )
        }
    }

    func tags() throws -> [LibraryTag] {
        let statement = try prepare("""
            SELECT t.id, t.name, t.color, COUNT(at.asset_id)
            FROM tags t LEFT JOIN asset_tags at ON at.tag_id = t.id
            GROUP BY t.id ORDER BY t.name COLLATE NOCASE
            """)
        defer { sqlite3_finalize(statement) }
        var result: [LibraryTag] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0)) else { continue }
            result.append(LibraryTag(
                id: id,
                name: text(statement, 1),
                color: LibraryTagColor(rawValue: text(statement, 2)) ?? .gray,
                itemCount: Int(sqlite3_column_int64(statement, 3))
            ))
        }
        return result
    }

    func collections() throws -> [MediaCollection] {
        let statement = try prepare("""
            SELECT c.id, c.name, COUNT(ci.id)
            FROM collections c LEFT JOIN collection_items ci ON ci.collection_id = c.id
            GROUP BY c.id ORDER BY c.name COLLATE NOCASE
            """)
        defer { sqlite3_finalize(statement) }
        var result: [MediaCollection] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0)) else { continue }
            result.append(MediaCollection(
                id: id,
                name: text(statement, 1),
                itemCount: Int(sqlite3_column_int64(statement, 2))
            ))
        }
        return result
    }

    @discardableResult
    func createTag(name: String, color: LibraryTagColor) throws -> LibraryTag {
        let cleanName = try validatedName(name)
        let id = UUID()
        let statement = try prepare("INSERT INTO tags(id, name, normalized_name, color) VALUES(?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        bind(cleanName, to: 2, in: statement)
        bind(Self.normalized(cleanName), to: 3, in: statement)
        bind(color.rawValue, to: 4, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw mappedDatabaseError() }
        return LibraryTag(id: id, name: cleanName, color: color, itemCount: 0)
    }

    func updateTag(id: UUID, name: String, color: LibraryTagColor, mergeOnConflict: Bool) throws {
        let cleanName = try validatedName(name)
        if let conflict = try tagID(normalizedName: Self.normalized(cleanName)), conflict != id {
            guard mergeOnConflict else { throw RepositoryError.duplicateName }
            try transaction {
                let merge = try prepare("INSERT OR IGNORE INTO asset_tags(asset_id, tag_id) SELECT asset_id, ? FROM asset_tags WHERE tag_id = ?")
                defer { sqlite3_finalize(merge) }
                bind(conflict.uuidString, to: 1, in: merge)
                bind(id.uuidString, to: 2, in: merge)
                try stepDone(merge)
                try deleteTag(id: id)
            }
            return
        }
        let statement = try prepare("UPDATE tags SET name = ?, normalized_name = ?, color = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(cleanName, to: 1, in: statement)
        bind(Self.normalized(cleanName), to: 2, in: statement)
        bind(color.rawValue, to: 3, in: statement)
        bind(id.uuidString, to: 4, in: statement)
        try stepDone(statement)
    }

    func deleteTag(id: UUID) throws {
        let statement = try prepare("DELETE FROM tags WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    func setTag(_ tagID: UUID, on assetIDs: [UUID], enabled: Bool) throws {
        try transaction {
            for assetID in assetIDs {
                let sql = enabled
                    ? "INSERT OR IGNORE INTO asset_tags(asset_id, tag_id) VALUES(?, ?)"
                    : "DELETE FROM asset_tags WHERE asset_id = ? AND tag_id = ?"
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                bind(assetID.uuidString, to: 1, in: statement)
                bind(tagID.uuidString, to: 2, in: statement)
                try stepDone(statement)
            }
        }
    }

    func tagIDs(for assetIDs: [UUID]) throws -> Set<UUID> {
        guard !assetIDs.isEmpty else { return [] }
        let placeholders = assetIDs.map { _ in "?" }.joined(separator: ",")
        let statement = try prepare("SELECT tag_id FROM asset_tags WHERE asset_id IN (\(placeholders)) GROUP BY tag_id HAVING COUNT(DISTINCT asset_id) = ?")
        defer { sqlite3_finalize(statement) }
        for (index, id) in assetIDs.enumerated() { bind(id.uuidString, to: Int32(index + 1), in: statement) }
        sqlite3_bind_int64(statement, Int32(assetIDs.count + 1), sqlite3_int64(assetIDs.count))
        var result: Set<UUID> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: text(statement, 0)) { result.insert(id) }
        }
        return result
    }

    func setFavorite(_ favorite: Bool, assetIDs: [UUID]) throws {
        guard !assetIDs.isEmpty else { return }
        let placeholders = assetIDs.map { _ in "?" }.joined(separator: ",")
        let statement = try prepare("UPDATE assets SET favorite = ? WHERE id IN (\(placeholders))")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, favorite ? 1 : 0)
        for (index, id) in assetIDs.enumerated() { bind(id.uuidString, to: Int32(index + 2), in: statement) }
        try stepDone(statement)
    }

    func allFavorite(assetIDs: [UUID]) throws -> Bool {
        guard !assetIDs.isEmpty else { return false }
        let placeholders = assetIDs.map { _ in "?" }.joined(separator: ",")
        let statement = try prepare("SELECT COUNT(*) FROM assets WHERE favorite = 1 AND id IN (\(placeholders))")
        defer { sqlite3_finalize(statement) }
        for (index, id) in assetIDs.enumerated() { bind(id.uuidString, to: Int32(index + 1), in: statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return Int(sqlite3_column_int64(statement, 0)) == assetIDs.count
    }

    @discardableResult
    func createCollection(name: String) throws -> MediaCollection {
        let cleanName = try validatedName(name)
        guard try collectionID(normalizedName: Self.normalized(cleanName)) == nil else {
            throw RepositoryError.duplicateName
        }
        let id = UUID()
        let statement = try prepare("INSERT INTO collections(id, name, normalized_name, created_at) VALUES(?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        bind(cleanName, to: 2, in: statement)
        bind(Self.normalized(cleanName), to: 3, in: statement)
        sqlite3_bind_double(statement, 4, Date().timeIntervalSinceReferenceDate)
        try stepDone(statement)
        return MediaCollection(id: id, name: cleanName, itemCount: 0)
    }

    func renameCollection(id: UUID, name: String) throws {
        let cleanName = try validatedName(name)
        if let conflict = try collectionID(normalizedName: Self.normalized(cleanName)), conflict != id {
            throw RepositoryError.duplicateName
        }
        let statement = try prepare("UPDATE collections SET name = ?, normalized_name = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(cleanName, to: 1, in: statement)
        bind(Self.normalized(cleanName), to: 2, in: statement)
        bind(id.uuidString, to: 3, in: statement)
        try stepDone(statement)
    }

    func deleteCollection(id: UUID) throws {
        let statement = try prepare("DELETE FROM collections WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    func add(assetIDs: [UUID], to collectionID: UUID) throws {
        var nextPosition = try maximumPosition(in: collectionID) + 1
        try transaction {
            for assetID in assetIDs {
                let statement = try prepare("INSERT OR IGNORE INTO collection_items(id, collection_id, asset_id, position) VALUES(?, ?, ?, ?)")
                defer { sqlite3_finalize(statement) }
                bind(UUID().uuidString, to: 1, in: statement)
                bind(collectionID.uuidString, to: 2, in: statement)
                bind(assetID.uuidString, to: 3, in: statement)
                sqlite3_bind_int64(statement, 4, sqlite3_int64(nextPosition))
                try stepDone(statement)
                if sqlite3_changes(db) > 0 { nextPosition += 1 }
            }
        }
    }

    func remove(assetIDs: [UUID], from collectionID: UUID) throws {
        guard !assetIDs.isEmpty else { return }
        let placeholders = assetIDs.map { _ in "?" }.joined(separator: ",")
        let statement = try prepare("DELETE FROM collection_items WHERE collection_id = ? AND asset_id IN (\(placeholders))")
        defer { sqlite3_finalize(statement) }
        bind(collectionID.uuidString, to: 1, in: statement)
        for (index, id) in assetIDs.enumerated() { bind(id.uuidString, to: Int32(index + 2), in: statement) }
        try stepDone(statement)
        try normalizePositions(collectionID)
    }

    func removeMissingMembership(id: UUID) throws {
        let statement = try prepare("DELETE FROM collection_items WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    func reorder(collectionID: UUID, assetID: UUID, before beforeID: UUID?) throws {
        var ids = try collectionAssetIDs(collectionID)
        guard let source = ids.firstIndex(of: assetID) else { return }
        ids.remove(at: source)
        if let beforeID, let destination = ids.firstIndex(of: beforeID) {
            ids.insert(assetID, at: destination)
        } else {
            ids.append(assetID)
        }
        try transaction {
            for (index, id) in ids.enumerated() {
                let statement = try prepare("UPDATE collection_items SET position = ? WHERE collection_id = ? AND asset_id = ?")
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, sqlite3_int64(index))
                bind(collectionID.uuidString, to: 2, in: statement)
                bind(id.uuidString, to: 3, in: statement)
                try stepDone(statement)
            }
        }
    }

    func assetIDs(for urls: [URL], roots: [URL]) throws -> [UUID] {
        var ids: [UUID] = []
        for url in urls {
            guard Self.isInside(url, roots: roots), let id = try assetID(for: url) else {
                throw RepositoryError.outsideLibrary
            }
            ids.append(id)
        }
        return ids
    }

    func attachLibraryIdentity(to items: [MediaItem], roots: [URL]) throws -> [MediaItem] {
        var resolved: [MediaItem] = []
        resolved.reserveCapacity(items.count)
        var idsNeedingTags: [UUID] = []
        for item in items {
            guard Self.isInside(item.url, roots: roots),
                  let identity = try assetIdentity(for: item.url) else {
                resolved.append(item)
                continue
            }
            idsNeedingTags.append(identity.id)
            resolved.append(MediaItem(
                libraryID: identity.id,
                isFavorite: identity.favorite,
                url: item.url,
                type: item.type,
                name: item.name,
                duration: item.duration,
                width: item.width,
                height: item.height,
                bitRate: item.bitRate,
                sampleRate: item.sampleRate,
                channelCount: item.channelCount,
                fileSize: item.fileSize,
                modifiedAt: item.modifiedAt,
                addedAt: item.addedAt
            ))
        }

        guard !idsNeedingTags.isEmpty else { return resolved }
        let tagsByAsset = try tagMap(for: idsNeedingTags)
        return resolved.map { item in
            guard let id = item.libraryID, let tags = tagsByAsset[id] else { return item }
            var hydrated = item
            hydrated.tags = tags
            return hydrated
        }
    }

    func relink(assetID: UUID, to url: URL, roots: [URL]) throws {
        guard Self.isInside(url, roots: roots), let type = Self.mediaType(for: url) else {
            throw RepositoryError.outsideLibrary
        }
        guard let root = roots.map(\.standardizedFileURL).first(where: { Self.isDescendant(url, of: $0) }) else {
            throw RepositoryError.outsideLibrary
        }
        let values = try url.resourceValues(forKeys: Self.resourceKeys)
        let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1)))
        let statement = try prepare("""
            UPDATE assets SET root_path = ?, relative_path = ?, resource_id = ?, name = ?,
                media_type = ?, file_size = ?, modified_at = ?, added_at = ?, available = 1
            WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(root.path, to: 1, in: statement)
        bind(relative, to: 2, in: statement)
        bind(Self.resourceIdentifier(values.fileResourceIdentifier), to: 3, in: statement)
        bind(url.lastPathComponent, to: 4, in: statement)
        sqlite3_bind_int(statement, 5, Int32(type.databaseValue))
        bind(values.fileSize.map(Int64.init), to: 6, in: statement)
        bind(values.contentModificationDate, to: 7, in: statement)
        bind(values.addedToDirectoryDate, to: 8, in: statement)
        bind(assetID.uuidString, to: 9, in: statement)
        try stepDone(statement)
    }

    // MARK: - Reconciliation

    private func upsert(_ candidate: Candidate) throws {
        let existingID = try matchedAssetID(candidate)
        let id = existingID ?? UUID()
        let statement = try prepare("""
            INSERT INTO assets(id, root_path, relative_path, resource_id, name, media_type,
                               file_size, modified_at, added_at, available, favorite)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0)
            ON CONFLICT(id) DO UPDATE SET root_path=excluded.root_path,
                relative_path=excluded.relative_path, resource_id=excluded.resource_id,
                name=excluded.name, media_type=excluded.media_type, file_size=excluded.file_size,
                modified_at=excluded.modified_at, added_at=excluded.added_at, available=1
            """)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        bind(candidate.rootPath, to: 2, in: statement)
        bind(candidate.relativePath, to: 3, in: statement)
        bind(candidate.resourceID, to: 4, in: statement)
        bind(candidate.item.name, to: 5, in: statement)
        sqlite3_bind_int(statement, 6, Int32(candidate.item.type.databaseValue))
        bind(candidate.item.fileSize, to: 7, in: statement)
        bind(candidate.item.modifiedAt, to: 8, in: statement)
        bind(candidate.item.addedAt, to: 9, in: statement)
        try stepDone(statement)
    }

    /// Reconcile identity in order of confidence: filesystem identity first (so a
    /// file that was renamed or moved between authorized roots keeps its asset
    /// ID and organization), then the exact stored path, then a lightweight
    /// name + size + modified-time fingerprint for files whose identifier is
    /// unavailable. Fallback lookups are restricted to rows not yet reclaimed in
    /// this reconcile pass so two candidates cannot claim the same asset.
    private func matchedAssetID(_ candidate: Candidate) throws -> UUID? {
        if let resourceID = candidate.resourceID {
            let statement = try prepare("SELECT id FROM assets WHERE resource_id = ? AND available = 0 LIMIT 1")
            defer { sqlite3_finalize(statement) }
            bind(resourceID, to: 1, in: statement)
            if sqlite3_step(statement) == SQLITE_ROW { return UUID(uuidString: text(statement, 0)) }
        }

        let pathStatement = try prepare("SELECT id FROM assets WHERE root_path = ? AND relative_path = ? LIMIT 1")
        defer { sqlite3_finalize(pathStatement) }
        bind(candidate.rootPath, to: 1, in: pathStatement)
        bind(candidate.relativePath, to: 2, in: pathStatement)
        if sqlite3_step(pathStatement) == SQLITE_ROW { return UUID(uuidString: text(pathStatement, 0)) }

        guard let size = candidate.item.fileSize, let modified = candidate.item.modifiedAt else { return nil }
        let fallback = try prepare("""
            SELECT id FROM assets
            WHERE available = 0 AND name = ? AND file_size = ? AND modified_at = ?
            LIMIT 1
            """)
        defer { sqlite3_finalize(fallback) }
        bind(candidate.item.name, to: 1, in: fallback)
        sqlite3_bind_int64(fallback, 2, sqlite3_int64(size))
        sqlite3_bind_double(fallback, 3, modified.timeIntervalSinceReferenceDate)
        return sqlite3_step(fallback) == SQLITE_ROW ? UUID(uuidString: text(fallback, 0)) : nil
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        .addedToDirectoryDateKey, .fileResourceIdentifierKey,
    ]

    /// Recursively collect media under `root`, applying `policy` before entering
    /// any subdirectory so trees such as `node_modules` are never listed.
    private static func candidates(in root: URL, policy: FolderScanPolicy) throws -> [Candidate] {
        var result: [Candidate] = []
        try FolderScanWalker.forEachRegularFile(in: root, keys: resourceKeys, policy: policy) { url, values in
            guard values.isRegularFile == true, let type = mediaType(for: url) else { return }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1)))
            result.append(Candidate(
                rootPath: root.path,
                relativePath: relative,
                resourceID: resourceIdentifier(values.fileResourceIdentifier),
                item: MediaItem(
                    url: url,
                    type: type,
                    name: url.lastPathComponent,
                    fileSize: values.fileSize.map(Int64.init),
                    modifiedAt: values.contentModificationDate,
                    addedAt: values.addedToDirectoryDate
                )
            ))
        }
        return result
    }

    private static func mediaType(for url: URL) -> MediaType? {
        if let contentType = UTType(filenameExtension: url.pathExtension) {
            return MediaType(contentType: contentType)
        }
        return nil
    }

    private static func resourceIdentifier(_ value: (any NSCopying & NSSecureCoding & NSObjectProtocol)?) -> String? {
        guard let value else { return nil }
        if let data = value as? Data { return data.base64EncodedString() }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    private static func isInside(_ url: URL, roots: [URL]) -> Bool {
        roots.contains { isDescendant(url, of: $0) }
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    // MARK: - SQLite

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS assets(
                id TEXT PRIMARY KEY, root_path TEXT NOT NULL, relative_path TEXT NOT NULL,
                resource_id TEXT, name TEXT NOT NULL, media_type INTEGER NOT NULL,
                file_size INTEGER, modified_at REAL, added_at REAL,
                available INTEGER NOT NULL DEFAULT 1, favorite INTEGER NOT NULL DEFAULT 0,
                UNIQUE(root_path, relative_path)
            );
            CREATE INDEX IF NOT EXISTS assets_resource ON assets(root_path, resource_id);
            CREATE TABLE IF NOT EXISTS tags(
                id TEXT PRIMARY KEY, name TEXT NOT NULL, normalized_name TEXT NOT NULL UNIQUE,
                color TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS asset_tags(
                asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY(asset_id, tag_id)
            );
            CREATE TABLE IF NOT EXISTS collections(
                id TEXT PRIMARY KEY, name TEXT NOT NULL, normalized_name TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS collection_items(
                id TEXT PRIMARY KEY, collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                position INTEGER NOT NULL, UNIQUE(collection_id, asset_id)
            );
            CREATE INDEX IF NOT EXISTS collection_order ON collection_items(collection_id, position);
            PRAGMA user_version = 1;
            """)
    }

    private static func defaultDatabaseURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Flicksy", directoryHint: .isDirectory)
            .appending(path: "library.sqlite3", directoryHint: .notDirectory)
    }

    private func requireDatabase() throws {
        guard db != nil else { throw RepositoryError.database("The library database could not be opened.") }
    }

    private func execute(_ sql: String) throws {
        try requireDatabase()
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unknown database error"
            sqlite3_free(error)
            throw RepositoryError.database(message)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        try requireDatabase()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw mappedDatabaseError()
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw mappedDatabaseError() }
    }

    private func mappedDatabaseError() -> Error {
        if sqlite3_errcode(db) == SQLITE_CONSTRAINT { return RepositoryError.duplicateName }
        return RepositoryError.database(String(cString: sqlite3_errmsg(db)))
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }

    private func bind(_ value: Date?, to index: Int32, in statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_double(statement, index, value.timeIntervalSinceReferenceDate)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func optionalInt64(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int64(sqlite3_column_int64(statement, column))
    }

    private func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
    }

    private func validatedName(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw RepositoryError.invalidName }
        return clean
    }

    private static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tagID(normalizedName: String) throws -> UUID? {
        let statement = try prepare("SELECT id FROM tags WHERE normalized_name = ?")
        defer { sqlite3_finalize(statement) }
        bind(normalizedName, to: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? UUID(uuidString: text(statement, 0)) : nil
    }

    private func collectionID(normalizedName: String) throws -> UUID? {
        let statement = try prepare("SELECT id FROM collections WHERE normalized_name = ?")
        defer { sqlite3_finalize(statement) }
        bind(normalizedName, to: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? UUID(uuidString: text(statement, 0)) : nil
    }

    private func assetID(for url: URL) throws -> UUID? {
        let path = url.standardizedFileURL.path
        let statement = try prepare("SELECT id FROM assets WHERE available = 1 AND root_path || '/' || relative_path = ?")
        defer { sqlite3_finalize(statement) }
        bind(path, to: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? UUID(uuidString: text(statement, 0)) : nil
    }

    private func assetIdentity(for url: URL) throws -> (id: UUID, favorite: Bool)? {
        let path = url.standardizedFileURL.path
        let statement = try prepare("SELECT id, favorite FROM assets WHERE available = 1 AND root_path || '/' || relative_path = ?")
        defer { sqlite3_finalize(statement) }
        bind(path, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let id = UUID(uuidString: text(statement, 0)) else { return nil }
        return (id, sqlite3_column_int(statement, 1) != 0)
    }

    private func tagMap(for assetIDs: [UUID]) throws -> [UUID: [LibraryTag]] {
        guard !assetIDs.isEmpty else { return [:] }
        let placeholders = assetIDs.map { _ in "?" }.joined(separator: ",")
        let statement = try prepare("""
            SELECT at.asset_id, t.id, t.name, t.color
            FROM asset_tags at JOIN tags t ON t.id = at.tag_id
            WHERE at.asset_id IN (\(placeholders))
            ORDER BY t.name COLLATE NOCASE
            """)
        defer { sqlite3_finalize(statement) }
        for (index, id) in assetIDs.enumerated() { bind(id.uuidString, to: Int32(index + 1), in: statement) }
        var map: [UUID: [LibraryTag]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let assetID = UUID(uuidString: text(statement, 0)),
                  let tagID = UUID(uuidString: text(statement, 1))
            else { continue }
            let tag = LibraryTag(
                id: tagID,
                name: text(statement, 2),
                color: LibraryTagColor(rawValue: text(statement, 3)) ?? .gray,
                itemCount: 0
            )
            map[assetID, default: []].append(tag)
        }
        return map
    }

    private func maximumPosition(in collectionID: UUID) throws -> Int {
        let statement = try prepare("SELECT COALESCE(MAX(position), -1) FROM collection_items WHERE collection_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(collectionID.uuidString, to: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
    }

    private func collectionAssetIDs(_ collectionID: UUID) throws -> [UUID] {
        let statement = try prepare("SELECT asset_id FROM collection_items WHERE collection_id = ? ORDER BY position")
        defer { sqlite3_finalize(statement) }
        bind(collectionID.uuidString, to: 1, in: statement)
        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: text(statement, 0)) { ids.append(id) }
        }
        return ids
    }

    private func normalizePositions(_ collectionID: UUID) throws {
        let ids = try collectionAssetIDs(collectionID)
        for (index, id) in ids.enumerated() {
            let statement = try prepare("UPDATE collection_items SET position = ? WHERE collection_id = ? AND asset_id = ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, sqlite3_int64(index))
            bind(collectionID.uuidString, to: 2, in: statement)
            bind(id.uuidString, to: 3, in: statement)
            try stepDone(statement)
        }
    }
}

extension MediaType {
    fileprivate var databaseValue: Int {
        switch self {
        case .image: 0
        case .video: 1
        case .audio: 2
        }
    }

    fileprivate init?(databaseValue: Int) {
        switch databaseValue {
        case 0: self = .image
        case 1: self = .video
        case 2: self = .audio
        default: return nil
        }
    }
}

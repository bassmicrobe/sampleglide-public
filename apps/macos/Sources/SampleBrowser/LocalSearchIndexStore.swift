import Foundation
import SQLite3

struct LocalIndexSource: Equatable, Sendable {
    let id: UUID
    let path: String
    let name: String
}

struct LocalIndexItem: Equatable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let sourceID: UUID
}

struct LocalIndexAnnotation: Equatable, Sendable {
    let path: String
    let notes: String
    let tags: [String]
}

struct LocalIndexDirectoryWork: Equatable, Sendable {
    let sourceID: UUID
    let sourcePath: String
    let path: String
    let scanID: Int64
    let failureCount: Int

    init(sourceID: UUID, sourcePath: String, path: String, scanID: Int64, failureCount: Int = 0) {
        self.sourceID = sourceID
        self.sourcePath = sourcePath
        self.path = path
        self.scanID = scanID
        self.failureCount = failureCount
    }
}

struct LocalIndexStatus: Equatable, Sendable {
    let sourceID: UUID
    let sourcePath: String
    let sourceName: String
    /// Per-source count; overlapping sources can contain the same indexed path.
    let indexedCount: Int
    let pendingDirectoryCount: Int
    /// Directory checkpoints consumed in this scan, including failed listings.
    let processedDirectoryCount: Int
    let lastCompletedAt: Date?
    let error: String?
}

struct LocalIndexSearchHit: Equatable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let sourceID: UUID
    let sourceName: String
    let notes: String
    let tags: [String]
}

struct LocalIndexSearchPage: Equatable, Sendable {
    let items: [LocalIndexSearchHit]
    let hasMore: Bool
    let offset: Int
}

/// A resumable, metadata-only index. SQLite work is actor-isolated and never reads sample files.
actor LocalSearchIndexStore {
    private let database: LocalIndexDatabase
    private let retryDelays: [TimeInterval]
    private var indexedCounts: [String: Int] = [:]
    private var indexedCountsUpdatedAt: Date?
    private let indexedCountRefreshInterval: TimeInterval = 5

    init(databaseURL: URL, retryDelays: [TimeInterval] = [2, 10]) throws {
        database = try LocalIndexDatabase(url: databaseURL)
        self.retryDelays = [2.0, 10.0].enumerated().map { index, fallback in
            guard retryDelays.indices.contains(index), retryDelays[index].isFinite, retryDelays[index] > 0 else { return fallback }
            return retryDelays[index]
        }
    }

    /// New and relocated sources start a scan; unchanged sources resume their durable queue.
    func configureSources(_ sources: [LocalIndexSource]) throws {
        guard Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ Self.validPath($0.path) }) else {
            throw LocalIndexDatabaseError.invalidPath
        }
        try database.transaction {
            let existing = try database.prepare("SELECT id, path FROM sources")
            var oldPaths: [String: String] = [:]
            while try existing.step() { oldPaths[existing.text(0)] = existing.text(1) }
            let currentIDs = Set(sources.map { $0.id.uuidString })
            var removedMemberships = false
            for id in oldPaths.keys where !currentIDs.contains(id) {
                try database.run("DELETE FROM sources WHERE id = ?", [.text(id)])
                removedMemberships = true
            }
            for source in sources {
                let id = source.id.uuidString
                if let oldPath = oldPaths[id], oldPath != source.path {
                    try database.run("DELETE FROM sources WHERE id = ?", [.text(id)])
                    removedMemberships = true
                }
                if oldPaths[id] != source.path {
                    let generation = try nextScanID()
                    try database.run("INSERT INTO sources(id, path, name, generation) VALUES (?, ?, ?, ?)",
                                     [.text(id), .text(source.path), .text(source.name), .integer(generation)])
                    try database.run("INSERT INTO pending_directories(source_id, path, generation) VALUES (?, ?, ?)",
                                     [.text(id), .text(source.path), .integer(generation)])
                } else {
                    try database.run("UPDATE sources SET name = ? WHERE id = ?", [.text(source.name), .text(id)])
                }
            }
            // Unchanged/new sources cannot create orphaned rows. Avoid walking
            // the entire item index on launch or a source-name change.
            if removedMemberships { try removeUnreferencedItems() }
        }
        indexedCountsUpdatedAt = nil
    }

    /// Replaces annotation metadata atomically, updating only affected search documents.
    func replaceAnnotations(_ annotations: [LocalIndexAnnotation]) throws {
        guard annotations.allSatisfy({ Self.validPath($0.path) }) else { throw LocalIndexDatabaseError.invalidPath }
        // Annotation documents are small; the sample index itself never enters memory.
        var current: [String: LocalIndexAnnotation] = [:]
        for annotation in annotations { current[annotation.path] = annotation }
        try database.transaction {
            let old = try database.prepare("SELECT path, notes, tags_json FROM annotations")
            var changedPaths = Set<String>()
            var deletedPaths: [String] = []
            while try old.step() {
                let path = old.text(0)
                let previous = LocalIndexAnnotation(path: path, notes: old.text(1), tags: Self.decodeTags(old.text(2)))
                if current[path] != previous { changedPaths.insert(path) }
                if current[path] == nil {
                    deletedPaths.append(path)
                }
            }
            for path in deletedPaths {
                try database.run("DELETE FROM annotations WHERE path = ?", [.text(path)])
            }
            let upsert = try database.prepare("""
                INSERT INTO annotations(path, notes, tags_json, folded_notes, folded_tags) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET notes = excluded.notes, tags_json = excluded.tags_json,
                    folded_notes = excluded.folded_notes, folded_tags = excluded.folded_tags
                WHERE notes != excluded.notes OR tags_json != excluded.tags_json
                """)
            for value in current.values {
                try upsert.bind([.text(value.path), .text(value.notes), .text(Self.encodeTags(value.tags)),
                                 .text(Self.fold(value.notes)), .text(Self.fold(value.tags.joined(separator: "\n")))])
                _ = try upsert.step()
                if database.changedRowCount > 0 { changedPaths.insert(value.path) }
                try upsert.reset()
            }
            let lookup = try database.prepare("""
                SELECT i.id, i.name, COALESCE(a.folded_notes, ''), COALESCE(a.folded_tags, '')
                FROM items i LEFT JOIN annotations a ON a.path = i.path WHERE i.path = ?
                """)
            let update = try database.prepare("UPDATE items SET searchable = ?, folded_tags = ? WHERE id = ?")
            for path in changedPaths {
                try lookup.bind([.text(path)])
                if try lookup.step() {
                    let searchable = Self.searchable(path: path, name: lookup.text(1), notes: lookup.text(2), tags: lookup.text(3))
                    try update.bind([.text(searchable), .text(lookup.text(3)), .integer(lookup.integer(0))])
                    _ = try update.step()
                    try update.reset()
                }
                try lookup.reset()
            }
        }
    }

    /// Failed listings remain durable while their bounded retry delay elapses.
    func nextDirectory(now: Date = Date()) throws -> LocalIndexDirectoryWork? {
        let statement = try database.prepare("""
            SELECT s.id, s.path, q.path, q.generation, q.failure_count
            FROM pending_directories q JOIN sources s ON s.id = q.source_id
            WHERE q.generation = s.generation AND q.retry_after <= ? ORDER BY q.id LIMIT 1
            """)
        try statement.bind([.real(now.timeIntervalSince1970)])
        guard try statement.step(), let sourceID = UUID(uuidString: statement.text(0)) else { return nil }
        return LocalIndexDirectoryWork(sourceID: sourceID, sourcePath: statement.text(1), path: statement.text(2),
                                       scanID: statement.integer(3), failureCount: Int(statement.integer(4)))
    }

    /// A nil ready item can mean delayed work, rather than a completed traversal.
    func nextRetryDate() throws -> Date? {
        let statement = try database.prepare("""
            SELECT MIN(q.retry_after) FROM pending_directories q JOIN sources s ON s.id = q.source_id
            WHERE q.generation = s.generation AND q.failure_count > 0
            """)
        guard try statement.step(), !statement.isNull(0) else { return nil }
        return Date(timeIntervalSince1970: statement.double(0))
    }

    /// Small commits let searches run between batches. The durable directory checkpoint remains
    /// until all rows and its child queue are saved, so interruption never skips a subtree.
    func applyDirectory(_ work: LocalIndexDirectoryWork, items: [LocalIndexItem], childDirectories: [String]) async throws {
        guard items.allSatisfy({ $0.sourceID == work.sourceID && Self.isChild($0.path, of: work.path) }),
              childDirectories.allSatisfy({ Self.isChild($0, of: work.path) }) else {
            throw LocalIndexDatabaseError.invalidPath
        }
        for start in stride(from: 0, to: items.count, by: 500) {
            try Task.checkCancellation()
            guard try isCurrent(work) else { return }
            try upsertItems(items[start..<min(start + 500, items.count)], for: work)
            await Task.yield()
        }
        try Task.checkCancellation()
        try database.transaction {
            guard try isCurrent(work) else { return }
            let enqueue = try database.prepare("INSERT OR IGNORE INTO pending_directories(source_id, path, generation) VALUES (?, ?, ?)")
            for path in Set(childDirectories) {
                try enqueue.bind([.text(work.sourceID.uuidString), .text(path), .integer(work.scanID)])
                _ = try enqueue.step()
                try enqueue.reset()
            }
            try finishDirectory(work)
        }
    }

    private func upsertItems(_ items: ArraySlice<LocalIndexItem>, for work: LocalIndexDirectoryWork) throws {
        try database.transaction {
            let annotation = try database.prepare("SELECT folded_notes, folded_tags FROM annotations WHERE path = ?")
            let upsert = try database.prepare("""
                INSERT INTO items(path, name, is_directory, searchable, folded_tags) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET name = excluded.name, is_directory = excluded.is_directory,
                    searchable = excluded.searchable, folded_tags = excluded.folded_tags
                WHERE name != excluded.name OR is_directory != excluded.is_directory
                    OR searchable != excluded.searchable OR folded_tags != excluded.folded_tags
                """)
            let membership = try database.prepare("""
                INSERT INTO source_items(source_id, item_id, seen_generation)
                SELECT ?, id, ? FROM items WHERE path = ?
                ON CONFLICT(source_id, item_id) DO UPDATE SET seen_generation = excluded.seen_generation
                """)
            for item in items {
                var notes = ""
                var tags = ""
                try annotation.bind([.text(item.path)])
                if try annotation.step() { notes = annotation.text(0); tags = annotation.text(1) }
                try annotation.reset()
                try upsert.bind([.text(item.path), .text(item.name), .integer(item.isDirectory ? 1 : 0),
                                 .text(Self.searchable(path: item.path, name: item.name, notes: notes, tags: tags)), .text(tags)])
                _ = try upsert.step()
                try upsert.reset()
                try membership.bind([.text(work.sourceID.uuidString), .integer(work.scanID), .text(item.path)])
                _ = try membership.step()
                try membership.reset()
            }
        }
    }

    /// Retry only this directory twice; a permanently failed scan retains its old entries.
    func failDirectory(_ work: LocalIndexDirectoryWork, message: String, now: Date = Date()) throws {
        try database.transaction {
            guard try isCurrent(work) else { return }
            let detail = "\(work.path): \(message)"
            if work.failureCount < retryDelays.count {
                let delay = retryDelays[work.failureCount]
                try database.run("""
                    UPDATE pending_directories SET failure_count = failure_count + 1, retry_after = ?, last_error = ?
                    WHERE source_id = ? AND path = ? AND generation = ? AND failure_count = ?
                    """, [.real(now.addingTimeInterval(delay).timeIntervalSince1970), .text(detail),
                          .text(work.sourceID.uuidString), .text(work.path), .integer(work.scanID), .integer(Int64(work.failureCount))])
                return
            }
            try database.run("UPDATE sources SET had_errors = 1, error = ? WHERE id = ?",
                             [.text(detail), .text(work.sourceID.uuidString)])
            try finishDirectory(work)
        }
    }

    /// Starts another generation for idle sources; active scans retain their checkpoints.
    func requestRescan() throws {
        try database.transaction {
            let sources = try database.prepare("""
                SELECT s.id, s.path FROM sources s
                WHERE NOT EXISTS (SELECT 1 FROM pending_directories q WHERE q.source_id = s.id)
                """)
            var rescans: [(String, String)] = []
            while try sources.step() { rescans.append((sources.text(0), sources.text(1))) }
            for (id, path) in rescans {
                let generation = try nextScanID()
                try database.run("UPDATE sources SET generation = ?, processed_directory_count = 0, had_errors = 0, error = NULL WHERE id = ?",
                                 [.integer(generation), .text(id)])
                try database.run("INSERT INTO pending_directories(source_id, path, generation) VALUES (?, ?, ?)",
                                 [.text(id), .text(path), .integer(generation)])
            }
        }
    }

    /// Explicit reads are fresh. Frequent progress reads can reuse membership
    /// counts for up to five seconds while queue/error/checkpoint data stays live.
    func status(refreshIndexedCounts: Bool = true, now: Date = Date()) throws -> [LocalIndexStatus] {
        let refreshCounts = refreshIndexedCounts
            || (indexedCountsUpdatedAt.map { now.timeIntervalSince($0) >= indexedCountRefreshInterval } ?? true)
        let count = refreshCounts ? "(SELECT COUNT(*) FROM source_items m WHERE m.source_id = s.id)" : "0"
        let statement = try database.prepare("""
            SELECT s.id, s.path, s.name,
                \(count),
                (SELECT COUNT(*) FROM pending_directories q WHERE q.source_id = s.id),
                s.last_completed_at,
                COALESCE(s.error, (SELECT q.last_error FROM pending_directories q
                    WHERE q.source_id = s.id AND q.generation = s.generation AND q.failure_count > 0
                    ORDER BY q.id LIMIT 1)),
                s.processed_directory_count
            FROM sources s ORDER BY s.name COLLATE NOCASE, s.path
            """)
        var result: [LocalIndexStatus] = []
        var refreshedCounts: [String: Int] = [:]
        while try statement.step() {
            let sourceID = statement.text(0)
            guard let id = UUID(uuidString: sourceID) else { continue }
            let indexedCount = refreshCounts ? Int(statement.integer(3)) : indexedCounts[sourceID, default: 0]
            if refreshCounts { refreshedCounts[sourceID] = indexedCount }
            result.append(LocalIndexStatus(sourceID: id, sourcePath: statement.text(1), sourceName: statement.text(2),
                                           indexedCount: indexedCount, pendingDirectoryCount: Int(statement.integer(4)),
                                           processedDirectoryCount: Int(statement.integer(7)),
                                           lastCompletedAt: statement.isNull(5) ? nil : Date(timeIntervalSince1970: statement.double(5)),
                                           error: statement.isNull(6) ? nil : statement.text(6)))
        }
        if refreshCounts {
            indexedCounts = refreshedCounts
            indexedCountsUpdatedAt = now
        }
        return result
    }

    /// Returns a bounded page of unique paths. Long terms use the trigram index, including Japanese substrings.
    func search(query: String, limit: Int = 200, offset: Int = 0) throws -> LocalIndexSearchPage {
        try Task.checkCancellation()
        let pageSize = min(max(limit, 1), 500)
        let pageOffset = max(offset, 0)
        let terms = Self.terms(query)
        var predicates: [String] = []
        var arguments: [LocalIndexSQLValue] = []
        let indexedTerms = terms.filter { $0.text.unicodeScalars.count >= 3 }
        if database.hasTrigramIndex && !indexedTerms.isEmpty {
            predicates.append("i.id IN (SELECT rowid FROM item_search WHERE item_search MATCH ?)")
            let match = indexedTerms.map { term in
                let column = term.tagOnly ? "folded_tags" : "searchable"
                return "\(column) : \"\(term.text.replacingOccurrences(of: "\"", with: "\"\""))\""
            }.joined(separator: " AND ")
            arguments.append(.text(match))
        }
        // instr is literal: %, _ and quotes are never interpreted as SQL wildcards.
        for term in terms {
            predicates.append("instr(i.\(term.tagOnly ? "folded_tags" : "searchable"), ?) > 0")
            arguments.append(.text(term.text))
        }
        let filtering = predicates.isEmpty ? "" : " AND " + predicates.joined(separator: " AND ")
        // Limit ordered candidates before joining source/annotation metadata.
        // Broad FTS matches otherwise hydrate every hit just to sort one page.
        let sql = """
            WITH page AS MATERIALIZED (
                SELECT i.id, i.path, i.name, i.is_directory FROM items i
                WHERE EXISTS (SELECT 1 FROM source_items m WHERE m.item_id = i.id)
                \(filtering)
                ORDER BY i.name COLLATE NOCASE, i.path
                LIMIT ? OFFSET ?
            )
            SELECT i.path, i.name, i.is_directory, s.id, s.name, COALESCE(a.notes, ''), COALESCE(a.tags_json, '[]')
            FROM page i
            JOIN source_items m ON m.item_id = i.id
            JOIN sources s ON s.id = m.source_id
            LEFT JOIN annotations a ON a.path = i.path
            WHERE m.source_id = (SELECT m2.source_id FROM source_items m2 WHERE m2.item_id = i.id ORDER BY m2.source_id LIMIT 1)
            ORDER BY i.name COLLATE NOCASE, i.path
            """
        arguments.append(.integer(Int64(pageSize + 1)))
        arguments.append(.integer(Int64(pageOffset)))
        sqlite3_progress_handler(database.connection, 1_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(database.connection, 0, nil, nil) }
        let statement = try database.prepare(sql)
        try statement.bind(arguments)
        var hits: [LocalIndexSearchHit] = []
        while try statement.step() {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: statement.text(3)) else { continue }
            hits.append(LocalIndexSearchHit(path: statement.text(0), name: statement.text(1), isDirectory: statement.integer(2) != 0,
                                            sourceID: id, sourceName: statement.text(4), notes: statement.text(5), tags: Self.decodeTags(statement.text(6))))
        }
        let hasMore = hits.count > pageSize
        if hasMore { hits.removeLast() }
        return LocalIndexSearchPage(items: hits, hasMore: hasMore, offset: pageOffset)
    }

    private func isCurrent(_ work: LocalIndexDirectoryWork) throws -> Bool {
        let statement = try database.prepare("""
            SELECT 1 FROM sources s JOIN pending_directories q ON q.source_id = s.id
            WHERE s.id = ? AND s.path = ? AND s.generation = ? AND q.path = ? AND q.generation = s.generation
                AND q.failure_count = ?
            """)
        try statement.bind([.text(work.sourceID.uuidString), .text(work.sourcePath), .integer(work.scanID), .text(work.path),
                            .integer(Int64(work.failureCount))])
        return try statement.step()
    }

    private func nextScanID() throws -> Int64 {
        // Never reuse a generation after a source is removed and re-added with the same ID/path.
        try database.run("UPDATE index_state SET value = value + 1 WHERE key = 'scan_generation'")
        let statement = try database.prepare("SELECT value FROM index_state WHERE key = 'scan_generation'")
        _ = try statement.step()
        return statement.integer(0)
    }

    private func finishDirectory(_ work: LocalIndexDirectoryWork) throws {
        let id = work.sourceID.uuidString
        try database.run("DELETE FROM pending_directories WHERE source_id = ? AND path = ? AND generation = ? AND failure_count = ?",
                         [.text(id), .text(work.path), .integer(work.scanID), .integer(Int64(work.failureCount))])
        guard database.changedRowCount > 0 else { return }
        try database.run("UPDATE sources SET processed_directory_count = processed_directory_count + 1 WHERE id = ? AND generation = ?",
                         [.text(id), .integer(work.scanID)])
        let pending = try database.prepare("SELECT 1 FROM pending_directories WHERE source_id = ? LIMIT 1")
        try pending.bind([.text(id)])
        guard try !pending.step() else { return }
        // The final status must include all committed batches, including those
        // retained when a terminal read failure prevents stale pruning.
        indexedCountsUpdatedAt = nil
        let source = try database.prepare("SELECT had_errors FROM sources WHERE id = ?")
        try source.bind([.text(id)])
        guard try source.step(), source.integer(0) == 0 else { return }
        try database.run("DELETE FROM source_items WHERE source_id = ? AND seen_generation != ?",
                         [.text(id), .integer(work.scanID)])
        try database.run("UPDATE sources SET last_completed_at = ?, error = NULL WHERE id = ?",
                         [.real(Date().timeIntervalSince1970), .text(id)])
        try removeUnreferencedItems()
    }

    private func removeUnreferencedItems() throws {
        try database.run("DELETE FROM items WHERE NOT EXISTS (SELECT 1 FROM source_items m WHERE m.item_id = items.id)")
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private static func isChild(_ path: String, of parent: String) -> Bool {
        guard validPath(path), validPath(parent), path != parent else { return false }
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        guard path.hasPrefix(prefix) else { return false }
        return !path.dropFirst(prefix.count).contains("/")
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func searchable(path: String, name: String, notes: String, tags: String) -> String {
        [fold(name), fold(path), notes, tags].joined(separator: "\n")
    }

    private static func terms(_ query: String) -> [(text: String, tagOnly: Bool)] {
        var values: [String] = []
        var current = ""
        var quoted = false
        for character in query {
            if character == "\"" { quoted.toggle() }
            else if character.isWhitespace && !quoted {
                if !current.isEmpty { values.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { values.append(current) }
        return values.compactMap { value in
            let tagOnly = value.hasPrefix("#")
            let text = fold(tagOnly ? String(value.dropFirst()) : value)
            return text.isEmpty ? nil : (text, tagOnly)
        }
    }

    private static func encodeTags(_ tags: [String]) -> String {
        String(data: (try? JSONEncoder().encode(tags)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    private static func decodeTags(_ value: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
    }
}

private enum LocalIndexSQLValue {
    case text(String)
    case integer(Int64)
    case real(Double)
}

private enum LocalIndexDatabaseError: LocalizedError {
    case sqlite(String)
    case invalidPath
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): return "検索インデックスを更新できませんでした: \(message)"
        case .invalidPath: return "検索インデックスのパスが不正です。"
        case .unsupportedVersion: return "この検索インデックスは新しいバージョンのアプリで作成されています。"
        }
    }
}

/// This connection is exclusively owned by LocalSearchIndexStore's actor after initialization.
private final class LocalIndexDatabase: @unchecked Sendable {
    let connection: OpaquePointer
    private(set) var hasTrigramIndex = false
    var changedRowCount: Int32 { sqlite3_changes(connection) }

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let handle { sqlite3_close_v2(handle) }
            throw LocalIndexDatabaseError.sqlite(message)
        }
        connection = handle
        sqlite3_busy_timeout(handle, 2_000)
        try run("PRAGMA foreign_keys = ON")
        try run("PRAGMA journal_mode = WAL")
        try run("PRAGMA synchronous = NORMAL")
        try run("PRAGMA cache_size = -8192")
        let version = try prepare("PRAGMA user_version")
        _ = try version.step()
        guard version.integer(0) <= 3 else { throw LocalIndexDatabaseError.unsupportedVersion }
        try execute("""
            CREATE TABLE IF NOT EXISTS sources(
                id TEXT PRIMARY KEY, path TEXT NOT NULL, name TEXT NOT NULL, generation INTEGER NOT NULL,
                had_errors INTEGER NOT NULL DEFAULT 0, last_completed_at REAL, error TEXT,
                processed_directory_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS items(
                id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, is_directory INTEGER NOT NULL,
                searchable TEXT NOT NULL, folded_tags TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS items_name ON items(name COLLATE NOCASE, path);
            CREATE TABLE IF NOT EXISTS source_items(
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE, seen_generation INTEGER NOT NULL,
                PRIMARY KEY(source_id, item_id)
            );
            CREATE INDEX IF NOT EXISTS source_items_item ON source_items(item_id, source_id);
            CREATE TABLE IF NOT EXISTS pending_directories(
                id INTEGER PRIMARY KEY AUTOINCREMENT, source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                path TEXT NOT NULL, generation INTEGER NOT NULL, failure_count INTEGER NOT NULL DEFAULT 0,
                retry_after REAL NOT NULL DEFAULT 0, last_error TEXT, UNIQUE(source_id, path, generation)
            );
            CREATE TABLE IF NOT EXISTS annotations(
                path TEXT PRIMARY KEY, notes TEXT NOT NULL, tags_json TEXT NOT NULL,
                folded_notes TEXT NOT NULL, folded_tags TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS index_state(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            INSERT OR IGNORE INTO index_state(key, value)
                SELECT 'scan_generation', COALESCE(MAX(generation), 0) FROM sources;
            """)
        try transaction {
            let columns = try prepare("PRAGMA table_info(sources)")
            var hasProcessedDirectoryCount = false
            while try columns.step() {
                if columns.text(1) == "processed_directory_count" { hasProcessedDirectoryCount = true }
            }
            if !hasProcessedDirectoryCount {
                try run("ALTER TABLE sources ADD COLUMN processed_directory_count INTEGER NOT NULL DEFAULT 0")
                // Version 1 already saved the discovered directory tree and its outstanding queue.
                // Recover progress once; subsequent status reads use the persisted counter directly.
                try run("""
                    UPDATE sources SET processed_directory_count = MAX(0,
                        (SELECT COUNT(*) FROM source_items m JOIN items i ON i.id = m.item_id
                         WHERE m.source_id = sources.id AND m.seen_generation = sources.generation AND i.is_directory = 1)
                        + 1
                        - (SELECT COUNT(*) FROM pending_directories q
                           WHERE q.source_id = sources.id AND q.generation = sources.generation))
                    """)
            }
            let pendingColumns = try prepare("PRAGMA table_info(pending_directories)")
            var pendingColumnNames = Set<String>()
            while try pendingColumns.step() { pendingColumnNames.insert(pendingColumns.text(1)) }
            if !pendingColumnNames.contains("failure_count") {
                try run("ALTER TABLE pending_directories ADD COLUMN failure_count INTEGER NOT NULL DEFAULT 0")
            }
            if !pendingColumnNames.contains("retry_after") {
                try run("ALTER TABLE pending_directories ADD COLUMN retry_after REAL NOT NULL DEFAULT 0")
            }
            if !pendingColumnNames.contains("last_error") {
                try run("ALTER TABLE pending_directories ADD COLUMN last_error TEXT")
            }
            try run("CREATE INDEX IF NOT EXISTS pending_directory_retries ON pending_directories(source_id, retry_after) WHERE failure_count > 0")
            // Preserve existing generations and legacy sticky errors: their failed paths were not saved.
            try run("PRAGMA user_version = 3")
        }
        let existingFTS = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'item_search'")
        let existed = try existingFTS.step()
        do {
            try execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS item_search USING fts5(
                    searchable, folded_tags, content='items', content_rowid='id', tokenize='trigram'
                );
                CREATE TRIGGER IF NOT EXISTS items_fts_insert AFTER INSERT ON items BEGIN
                    INSERT INTO item_search(rowid, searchable, folded_tags) VALUES (new.id, new.searchable, new.folded_tags);
                END;
                CREATE TRIGGER IF NOT EXISTS items_fts_delete AFTER DELETE ON items BEGIN
                    INSERT INTO item_search(item_search, rowid, searchable, folded_tags)
                    VALUES ('delete', old.id, old.searchable, old.folded_tags);
                END;
                CREATE TRIGGER IF NOT EXISTS items_fts_update AFTER UPDATE ON items BEGIN
                    INSERT INTO item_search(item_search, rowid, searchable, folded_tags)
                    VALUES ('delete', old.id, old.searchable, old.folded_tags);
                    INSERT INTO item_search(rowid, searchable, folded_tags) VALUES (new.id, new.searchable, new.folded_tags);
                END;
                """)
            if !existed { try run("INSERT INTO item_search(item_search) VALUES ('rebuild')") }
            hasTrigramIndex = true
        } catch LocalIndexDatabaseError.sqlite(let message) where message.contains("no such module") || message.contains("tokenizer") {
            // Older SDK SQLite builds can still use literal substring search.
            hasTrigramIndex = false
        }
    }

    deinit { sqlite3_close_v2(connection) }

    func prepare(_ sql: String) throws -> LocalIndexStatement {
        try LocalIndexStatement(database: connection, sql: sql)
    }

    func run(_ sql: String, _ values: [LocalIndexSQLValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() {}
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw LocalIndexDatabaseError.sqlite(String(cString: sqlite3_errmsg(connection)))
        }
    }

    func transaction(_ operation: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try operation()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }
}

private final class LocalIndexStatement {
    private let database: OpaquePointer
    private let statement: OpaquePointer

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else {
            throw LocalIndexDatabaseError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        statement = result
    }

    deinit { sqlite3_finalize(statement) }

    func bind(_ values: [LocalIndexSQLValue]) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let position = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, position, text, Int32(text.utf8.count), transient)
            case .integer(let integer): result = sqlite3_bind_int64(statement, position, integer)
            case .real(let double): result = sqlite3_bind_double(statement, position, double)
            }
            guard result == SQLITE_OK else { throw LocalIndexDatabaseError.sqlite(String(cString: sqlite3_errmsg(database))) }
        }
    }

    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        if result == SQLITE_INTERRUPT && Task<Never, Never>.isCancelled { throw CancellationError() }
        throw LocalIndexDatabaseError.sqlite(String(cString: sqlite3_errmsg(database)))
    }

    func reset() throws {
        guard sqlite3_reset(statement) == SQLITE_OK else { throw LocalIndexDatabaseError.sqlite(String(cString: sqlite3_errmsg(database))) }
        sqlite3_clear_bindings(statement)
    }

    func text(_ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
}

import Foundation
import SQLite3

/// Clippings on disk: an SQLite database with a full-text index, so lists load a page at a
/// time and searching doesn't read every clipping, however large History grows.
///
/// The bytes of each clipping stay in their own files (ClipStore's Content folder); this
/// holds their metadata. Small library data (pastebins, filters, snippets, tombstones) and
/// sync bookkeeping live in the `kv` table.
public final class ClipDatabase: @unchecked Sendable {
    public enum Filter: Equatable, Sendable {
        case history, pinned, all
        case pastebin(UUID)
    }

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw FilterError("Couldn't open the PasteLens database: \(message)")
        }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA foreign_keys = ON")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    // MARK: Schema

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version") ?? 0
        if version < 1 {
            try transaction {
                try exec("""
                CREATE TABLE IF NOT EXISTS clips (
                    id TEXT PRIMARY KEY,
                    copied_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    in_history INTEGER NOT NULL,
                    pinned INTEGER NOT NULL,
                    sensitive INTEGER NOT NULL,
                    content_hash TEXT NOT NULL,
                    expires_at REAL,
                    meta BLOB NOT NULL
                )
                """)
                try exec("CREATE INDEX IF NOT EXISTS clips_history ON clips(in_history, copied_at DESC)")
                try exec("CREATE INDEX IF NOT EXISTS clips_copied ON clips(copied_at DESC)")
                try exec("CREATE INDEX IF NOT EXISTS clips_hash ON clips(content_hash)")
                try exec("CREATE INDEX IF NOT EXISTS clips_pinned ON clips(pinned) WHERE pinned = 1")
                try exec("""
                CREATE TABLE IF NOT EXISTS clip_bins (
                    clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                    bin_id TEXT NOT NULL,
                    PRIMARY KEY (clip_id, bin_id)
                )
                """)
                try exec("CREATE INDEX IF NOT EXISTS clip_bins_bin ON clip_bins(bin_id)")
                // Trigram tokens match any part of a word, so "voic" finds "invoice", and give
                // typo-tolerant search something to rank by.
                try exec("CREATE VIRTUAL TABLE IF NOT EXISTS clip_text USING fts5(body, tokenize = 'trigram')")
                try exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB)")
                try exec("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            try transaction {
                // Deletions, so a sync can't bring something back: "kind:id" and when.
                try exec("CREATE TABLE IF NOT EXISTS tombstones (key TEXT PRIMARY KEY, at REAL NOT NULL)")
                try exec("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            try transaction {
                try exec("DROP TABLE IF EXISTS clip_text")
                try exec("CREATE VIRTUAL TABLE clip_text USING fts5(body, tokenize = 'trigram')")
                let all = try rows("SELECT rowid, meta FROM clips") { (sqlite3_column_int64($0, 0), Self.decode($0, 1)) }
                for (rowid, clip) in all {
                    guard let clip else { continue }
                    try run("INSERT INTO clip_text (rowid, body) VALUES (?, ?)", [Int(rowid), Self.searchBody(clip)])
                }
                try exec("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try transaction {
                try exec("CREATE INDEX IF NOT EXISTS clips_secrets ON clips(expires_at) WHERE sensitive = 1")
                try exec("PRAGMA user_version = 4")
            }
        }
    }

    // MARK: Tombstones

    public func tombstone(_ key: String) -> Date? {
        (try? rows("SELECT at FROM tombstones WHERE key = ?", [key]) { Date(timeIntervalSince1970: sqlite3_column_double($0, 0)) })?.first
    }

    public func setTombstone(_ key: String, at date: Date?) throws {
        if let date {
            try run("INSERT INTO tombstones (key, at) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET at = excluded.at",
                    [key, date.timeIntervalSince1970])
        } else {
            try run("DELETE FROM tombstones WHERE key = ?", [key])
        }
    }

    public func tombstoneKeys() -> [String] {
        (try? rows("SELECT key FROM tombstones") { Self.text($0, 0) }) ?? []
    }

    public func pruneTombstones(olderThan date: Date) throws {
        try run("DELETE FROM tombstones WHERE at < ?", [date.timeIntervalSince1970])
    }

    // MARK: Writing

    /// Inserts or replaces clippings, with their pastebins and search text.
    public func upsert(_ clips: [Clipping]) throws {
        guard !clips.isEmpty else { return }
        try transaction {
            for clip in clips {
                let meta = try SyncMerge.encode(clip)
                try run("""
                    INSERT INTO clips (id, copied_at, updated_at, in_history, pinned, sensitive, content_hash, expires_at, meta)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET copied_at = excluded.copied_at, updated_at = excluded.updated_at,
                        in_history = excluded.in_history, pinned = excluded.pinned, sensitive = excluded.sensitive,
                        content_hash = excluded.content_hash, expires_at = excluded.expires_at, meta = excluded.meta
                    """,
                    [clip.id.uuidString, clip.copiedAt.timeIntervalSince1970, clip.updatedAt.timeIntervalSince1970,
                     clip.inHistory, clip.pinned, clip.sensitive, clip.contentHash,
                     clip.expiresAt?.timeIntervalSince1970, meta])
                try run("DELETE FROM clip_bins WHERE clip_id = ?", [clip.id.uuidString])
                for bin in clip.pastebinIDs {
                    try run("INSERT OR IGNORE INTO clip_bins (clip_id, bin_id) VALUES (?, ?)", [clip.id.uuidString, bin.uuidString])
                }
                guard let rowid = try scalarInt("SELECT rowid FROM clips WHERE id = ?", [clip.id.uuidString]) else { continue }
                try run("DELETE FROM clip_text WHERE rowid = ?", [rowid])
                try run("INSERT INTO clip_text (rowid, body) VALUES (?, ?)", [rowid, Self.searchBody(clip)])
            }
        }
    }

    public func upsert(_ clip: Clipping) throws { try upsert([clip]) }

    public func delete(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            for id in ids {
                if let rowid = try scalarInt("SELECT rowid FROM clips WHERE id = ?", [id.uuidString]) {
                    try run("DELETE FROM clip_text WHERE rowid = ?", [rowid])
                }
                try run("DELETE FROM clips WHERE id = ?", [id.uuidString])
            }
        }
    }

    // MARK: Reading

    public func clip(_ id: UUID) -> Clipping? {
        (try? rows("SELECT meta FROM clips WHERE id = ?", [id.uuidString]) { Self.decode($0, 0) })?.first ?? nil
    }

    public func clips(_ ids: [UUID]) -> [Clipping] { ids.compactMap(clip) }

    /// The most recent clipping in History with this content, for spotting a repeat copy.
    public func historyClip(withHash hash: String) -> Clipping? {
        (try? rows("SELECT meta FROM clips WHERE content_hash = ? AND in_history = 1 ORDER BY copied_at DESC LIMIT 1", [hash]) { Self.decode($0, 0) })?
            .first ?? nil
    }

    public func anyClip(withHash hash: String) -> Bool {
        ((try? scalarInt("SELECT 1 FROM clips WHERE content_hash = ? LIMIT 1", [hash])) ?? nil) != nil
    }

    private static func whereClause(_ filter: Filter) -> (String, [Any?]) {
        switch filter {
        case .history: ("c.in_history = 1", [])
        case .pinned: ("c.pinned = 1", [])
        case .all: ("1 = 1", [])
        case .pastebin(let id): ("c.id IN (SELECT clip_id FROM clip_bins WHERE bin_id = ?)", [id.uuidString])
        }
    }

    public func count(_ filter: Filter) -> Int {
        let (clause, args) = Self.whereClause(filter)
        return ((try? scalarInt("SELECT COUNT(*) FROM clips c WHERE \(clause)", args)) ?? nil) ?? 0
    }

    public var totalCount: Int { ((try? scalarInt("SELECT COUNT(*) FROM clips")) ?? nil) ?? 0 }

    /// When each clipping was first copied and on which Mac, to start the Activity graph
    /// from what's already here.
    public func copyOrigins() -> [(origin: String, createdAt: Date)] {
        (try? rows("SELECT meta FROM clips") { Self.decode($0, 0) })?.compactMap { $0 }.map { ($0.origin, $0.createdAt) } ?? []
    }

    /// A page of clippings, newest first.
    public func page(_ filter: Filter, limit: Int, offset: Int = 0) -> [Clipping] {
        let (clause, args) = Self.whereClause(filter)
        return (try? rows("SELECT c.meta FROM clips c WHERE \(clause) ORDER BY c.copied_at DESC LIMIT ? OFFSET ?",
                          args + [limit, offset]) { Self.decode($0, 0) })?.compactMap { $0 } ?? []
    }

    /// Clippings matching a search, best first.
    ///
    /// The full-text index finds candidates, by substring when every word is found, and
    /// otherwise by how many three-letter pieces of the words they share, which tolerates
    /// typos. The candidates are then ranked with `FuzzySearch`, the same scoring as before.
    public func search(_ query: String, in filter: Filter, limit: Int) -> [Clipping] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return page(filter, limit: limit) }
        let (clause, args) = Self.whereClause(filter)
        let indexable = words.filter { $0.count >= 3 }
        var candidates: [Clipping] = []
        if indexable.isEmpty {
            // Too short to index: scan recent clippings only.
            candidates = page(filter, limit: 5_000)
        } else {
            let exact = indexable.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " AND ")
            candidates = (try? rows("""
                SELECT c.meta FROM clip_text t JOIN clips c ON c.rowid = t.rowid
                WHERE clip_text MATCH ? AND \(clause) ORDER BY c.copied_at DESC LIMIT 600
                """, [exact] + args) { Self.decode($0, 0) })?.compactMap { $0 } ?? []
            if candidates.count < limit {
                let grams = Set(indexable.flatMap(Self.trigrams))
                if !grams.isEmpty {
                    let loose = grams.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ")
                    let more = (try? rows("""
                        SELECT c.meta FROM clip_text t JOIN clips c ON c.rowid = t.rowid
                        WHERE clip_text MATCH ? AND \(clause) ORDER BY bm25(clip_text) LIMIT 400
                        """, [loose] + args) { Self.decode($0, 0) })?.compactMap { $0 } ?? []
                    let seen = Set(candidates.map(\.id))
                    candidates += more.filter { !seen.contains($0.id) }
                }
            }
        }
        return candidates.compactMap { clip -> (Clipping, Double)? in
            let text = clip.sensitive ? (clip.title ?? "") : clip.searchableText
            guard let score = FuzzySearch.score(query, in: text) else { return nil }
            return (clip, score)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.copiedAt > $1.0.copiedAt }
        .prefix(limit).map(\.0)
    }

    /// What a clipping is found by. Secrets only by their label, never by their text.
    static func searchBody(_ clip: Clipping) -> String {
        clip.sensitive ? (clip.title ?? "") : clip.searchableText
    }

    static func trigrams(_ word: String) -> [String] {
        let chars = Array(word)
        guard chars.count >= 3 else { return [] }
        return (0...(chars.count - 3)).map { String(chars[$0..<$0 + 3]) }
    }

    /// Walks clippings newest first, in batches, until `body` returns false. For smart
    /// pastebins, whose rules run in Swift.
    public func forEach(_ filter: Filter = .all, batch: Int = 500, _ body: (Clipping) -> Bool) {
        var offset = 0
        while true {
            let chunk = page(filter, limit: batch, offset: offset)
            for clip in chunk where !body(clip) { return }
            if chunk.count < batch { return }
            offset += batch
        }
    }

    /// History clippings past the limits, oldest last, that aren't pinned or in a pastebin.
    public func expired(keeping maxCount: Int, maxDays: Int, now: Date = Date()) -> [UUID] {
        var ids: [UUID] = []
        if maxCount > 0 {
            ids += (try? rows("""
                SELECT id FROM clips c WHERE in_history = 1 AND pinned = 0
                ORDER BY copied_at DESC LIMIT -1 OFFSET ?
                """, [maxCount]) { UUID(uuidString: Self.text($0, 0)) })?.compactMap { $0 } ?? []
        }
        if maxDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(maxDays) * 86_400).timeIntervalSince1970
            ids += (try? rows("SELECT id FROM clips WHERE in_history = 1 AND pinned = 0 AND copied_at < ?", [cutoff]) {
                UUID(uuidString: Self.text($0, 0))
            })?.compactMap { $0 } ?? []
        }
        return Array(Set(ids))
    }

    public func expiredSecrets(now: Date = Date()) -> [UUID] {
        (try? rows("SELECT id FROM clips WHERE sensitive = 1 AND expires_at < ?", [now.timeIntervalSince1970]) {
            UUID(uuidString: Self.text($0, 0))
        })?.compactMap { $0 } ?? []
    }

    public func ids(_ filter: Filter) -> [UUID] {
        let (clause, args) = Self.whereClause(filter)
        return (try? rows("SELECT c.id FROM clips c WHERE \(clause)", args) { UUID(uuidString: Self.text($0, 0)) })?.compactMap { $0 } ?? []
    }

    // MARK: Key-value

    public func data(forKey key: String) -> Data? {
        (try? rows("SELECT value FROM kv WHERE key = ?", [key]) { Self.blob($0, 0) })?.first ?? nil
    }

    public func set(_ data: Data?, forKey key: String) throws {
        if let data {
            try run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, data])
        } else {
            try run("DELETE FROM kv WHERE key = ?", [key])
        }
    }

    // MARK: SQLite plumbing

    public func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw FilterError("Database error: \(message)")
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw FilterError("Database error: \(String(cString: sqlite3_errmsg(db)))")
        }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, index)
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Bool: sqlite3_bind_int64(stmt, index, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), Self.transient) }
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    func run(_ sql: String, _ args: [Any?] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw FilterError("Database error: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func rows<T>(_ sql: String, _ args: [Any?] = [], _ map: (OpaquePointer?) -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(stmt)) }
        return out
    }

    func scalarInt(_ sql: String, _ args: [Any?] = []) throws -> Int? {
        try rows(sql, args) { sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int64($0, 0)) }.first ?? nil
    }

    static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    static func blob(_ stmt: OpaquePointer?, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count > 0, let pointer = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    static func decode(_ stmt: OpaquePointer?, _ column: Int32) -> Clipping? {
        try? SyncMerge.decode(Clipping.self, from: blob(stmt, column))
    }
}

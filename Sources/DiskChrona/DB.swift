import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DBError: Error, CustomStringConvertible { let description: String }

/// Minimal SQLite wrapper with a prepared-statement cache. Use each instance from a single queue.
final class DB {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else { throw DBError(description: "无法打开数据库 \(path)") }
        sqlite3_busy_timeout(handle, 5000)
        guard sqlite3_create_function_v2(handle, "is_swap", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let value = values?[0], let path = sqlite3_value_text(value) else { sqlite3_result_int(context, 0); return }
            sqlite3_result_int(context, isSwapFile(String(cString: path)) ? 1 : 0)
        }, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close(handle)
    }

    var lastInsertId: Int64 { sqlite3_last_insert_rowid(handle) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> Int {
        _ = try rows(sql, args) { _ in () }
        return Int(sqlite3_changes(handle))
    }

    func rows<T>(_ sql: String, _ args: [Any?] = [], map: (Row) throws -> T) throws -> [T] {
        let s = try statement(sql)
        defer { sqlite3_reset(s); sqlite3_clear_bindings(s) }
        for (i, arg) in args.enumerated() {
            let i = Int32(i + 1)
            switch arg {
            case let v as Int64: sqlite3_bind_int64(s, i, v)
            case let v as Int: sqlite3_bind_int64(s, i, Int64(v))
            case let v as Double: sqlite3_bind_double(s, i, v)
            case let v as String: sqlite3_bind_text(s, i, v, -1, transient)
            default: sqlite3_bind_null(s, i)
            }
        }
        var out: [T] = []
        while true {
            switch sqlite3_step(s) {
            case SQLITE_ROW: out.append(try map(Row(s: s)))
            case SQLITE_DONE: return out
            default: throw lastError()
            }
        }
    }

    func double(_ sql: String, _ args: [Any?] = []) throws -> Double? {
        try rows(sql, args) { $0.isNull(0) ? nil : $0.double(0) }.first ?? nil
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    func migrate() throws {
        try exec("""
            PRAGMA auto_vacuum = INCREMENTAL;
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS roots(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, excludes TEXT NOT NULL DEFAULT '', baseline_at REAL);
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, dev INTEGER, ino INTEGER, size INTEGER, alloc INTEGER, nlink INTEGER, mtime REAL, seen_at REAL) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS files_inode ON files(dev, ino);
            CREATE TABLE IF NOT EXISTS changes(id INTEGER PRIMARY KEY, ts_prev REAL, ts REAL, path TEXT, other_path TEXT, kind INTEGER, old_size INTEGER, new_size INTEGER, old_alloc INTEGER, new_alloc INTEGER);
            CREATE INDEX IF NOT EXISTS changes_ts ON changes(ts);
            CREATE INDEX IF NOT EXISTS changes_path ON changes(path, ts);
            CREATE TABLE IF NOT EXISTS sessions(id INTEGER PRIMARY KEY, started REAL, ended REAL);
            CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
            CREATE TABLE IF NOT EXISTS volume(ts REAL, free INTEGER);
            CREATE INDEX IF NOT EXISTS volume_ts ON volume(ts);
            """)
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let s = statements[sql] { return s }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else { throw lastError() }
        statements[sql] = s
        return s
    }

    private func lastError() -> DBError { DBError(description: String(cString: sqlite3_errmsg(handle))) }
}

struct Row {
    let s: OpaquePointer
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(s, i) }
    func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: double(i)) }
    func string(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(s, i) == SQLITE_NULL }
}

// MARK: - Models

struct Root: Identifiable, Hashable {
    let id: Int64
    let path: String
    let excludes: [String]
}

/// Stored as INTEGER; keep the order stable.
enum Kind: Int { case added, grew, shrank, deleted, moveIn, moveOut, scopeIn, scopeOut, firstSeen }

struct Change: Identifiable {
    static let columns = "id, ts_prev, ts, path, other_path, kind, old_size, new_size, old_alloc, new_alloc"
    let id: Int64
    let tsPrev, ts: Date
    let path: String
    let otherPath: String?
    let kind: Kind
    let oldSize, newSize, oldAlloc, newAlloc: Int64

    init(_ r: Row) {
        id = r.int(0); tsPrev = r.date(1); ts = r.date(2); path = r.string(3) ?? ""; otherPath = r.string(4)
        kind = Kind(rawValue: Int(r.int(5))) ?? .grew
        oldSize = r.int(6); newSize = r.int(7); oldAlloc = r.int(8); newAlloc = r.int(9)
    }
}

struct FileRow {
    static let columns = "path, dev, ino, size, alloc, nlink, mtime, seen_at"
    let path: String
    let dev, ino, size, alloc, nlink: Int64
    let mtime, seenAt: Double
    var sizes: (Int64, Int64) { (size, alloc) }

    init(_ r: Row) {
        path = r.string(0) ?? ""; dev = r.int(1); ino = r.int(2); size = r.int(3); alloc = r.int(4); nlink = r.int(5)
        mtime = r.double(6); seenAt = r.double(7)
    }

    init(_ path: String, _ s: Stat, seenAt: Double) {
        self.path = path; dev = s.dev; ino = s.ino; size = s.size; alloc = s.alloc; nlink = s.nlink; mtime = s.mtime; self.seenAt = seenAt
    }
}

struct RankRow: Identifiable, Hashable {
    var id: String { path }
    let name, path: String
    let isDir: Bool
    let net, growth: Int64
    let last: Date
}

enum Metric: String, CaseIterable {
    case size = "文件大小", alloc = "分配空间"
    var delta: String { self == .size ? "(new_size - old_size)" : "(new_alloc - old_alloc)" }
}

enum RankSort: String, CaseIterable { case growth = "累计增长", net = "净变化" }

func likePattern(_ s: String) -> String {
    "%" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
}

// MARK: - Queries

extension DB {
    func file(_ path: String) throws -> FileRow? {
        try rows("SELECT \(FileRow.columns) FROM files WHERE path = ?", [path], map: FileRow.init).first
    }

    /// Every path (hard link) known to hold this data.
    func files(dev: Int64, ino: Int64) throws -> [FileRow] {
        try rows("SELECT \(FileRow.columns) FROM files WHERE dev = ? AND ino = ?", [dev, ino], map: FileRow.init)
    }

    /// Net change and observed growth per file, or per child of `dir` when `byDir`.
    func ranking(_ iv: DateInterval, metric: Metric, sort: RankSort, search: String, byDir: Bool, dir: String, ignoreSwap: Bool = false) throws -> [RankRow] {
        let d = metric.delta
        let agg = "SUM(\(d)) AS net, SUM(MAX(\(d), 0)) AS growth, MAX(ts)"
        var filter = "ts >= ? AND ts <= ?"
        if ignoreSwap { filter += " AND NOT is_swap(path)" }
        var args: [Any?] = [iv.start.timeIntervalSince1970, iv.end.timeIntervalSince1970]
        if !search.isEmpty { filter += " AND path LIKE ? ESCAPE '\\'"; args.append(likePattern(search)) }
        let tail = " HAVING net != 0 OR growth != 0 ORDER BY \(sort == .net ? "net" : "growth") DESC LIMIT 500"
        func rank(_ name: String, _ path: String, _ isDir: Bool, _ r: Row, _ at: Int32) -> RankRow {
            RankRow(name: name, path: path, isDir: isDir, net: r.int(at), growth: r.int(at + 1), last: r.date(at + 2))
        }

        if !byDir {
            // Moves are directory transfers, not growth of the file itself.
            return try rows("SELECT path, \(agg) FROM changes WHERE \(filter) AND kind NOT IN (4, 5) GROUP BY path" + tail, args) { r in
                let p = r.string(0) ?? ""
                return rank((p as NSString).lastPathComponent, p, false, r, 1)
            }
        }
        let (lo, hi) = prefixRange(dir)
        let rest = "substr(path, \(lo.unicodeScalars.count + 1))"
        let child = "CASE WHEN instr(\(rest), '/') > 0 THEN substr(\(rest), 1, instr(\(rest), '/') - 1) ELSE \(rest) END"
        let sql = "SELECT \(child) AS child, MAX(instr(\(rest), '/') > 0), \(agg) FROM changes WHERE \(filter) AND path >= ? AND path < ? GROUP BY child" + tail
        let bounds: [Any?] = [lo, hi]
        return try rows(sql, args + bounds) { r in
            let name = r.string(0) ?? ""
            return rank(name, lo + name, r.int(1) != 0, r, 2)
        }
    }

    func timeline(_ iv: DateInterval, search: String, limit: Int) throws -> [Change] {
        var sql = "SELECT \(Change.columns) FROM changes WHERE ts >= ? AND ts <= ? AND kind != 5"
        var args: [Any?] = [iv.start.timeIntervalSince1970, iv.end.timeIntervalSince1970]
        if !search.isEmpty { sql += " AND path LIKE ? ESCAPE '\\'"; args.append(likePattern(search)) }
        return try rows(sql + " ORDER BY ts DESC, id DESC LIMIT \(limit)", args, map: Change.init)
    }

    /// Changes for a path in time order, following moves back to the file's earlier paths.
    func history(_ path: String) throws -> [Change] {
        var out: [Change] = []
        var p = path, before = Double.greatestFiniteMagnitude
        for _ in 0..<20 {
            var part = try rows("SELECT \(Change.columns) FROM changes WHERE path = ? AND kind != 5 AND ts <= ? ORDER BY ts, id", [p, before], map: Change.init)
            guard let i = part.lastIndex(where: { $0.kind == .moveIn }), let from = part[i].otherPath else { out = part + out; break }
            part.removeFirst(i)
            out = part + out
            p = from
            before = part[0].ts.timeIntervalSince1970
        }
        return out
    }

    func sessions(_ iv: DateInterval) throws -> [DateInterval] {
        try rows("SELECT started, ended FROM sessions WHERE ended >= ? AND started <= ? ORDER BY started",
                 [iv.start.timeIntervalSince1970, iv.end.timeIntervalSince1970]) { r in
            DateInterval(start: r.date(0), end: max(r.date(0), r.date(1)))
        }
    }
}

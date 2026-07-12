import Foundation
import SQLite3

// SQLite 数据层（schema、动态列、去重插入、统计等）。
// 直接用系统 SQLite3 C 库，无第三方依赖。

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBValue {
    case null
    case text(String)
    case int(Int)
    case double(Double)

    var stringValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }
    var intValue: Int? {
        if case .int(let n) = self { return n }
        return nil
    }
}

// 期刊维度统计：用于全部期刊列表与期刊策略洞察。
struct JournalStat: Identifiable, Equatable {
    var id: String { journal }
    let journal: String
    let total: Int
    let included: Int
    let excluded: Int
    var reviewed: Int { included + excluded }
    var rate: Double { reviewed > 0 ? Double(included) / Double(reviewed) : 0 }
}

enum DBError: Error, LocalizedError {
    case open(String)
    case sql(String)
    case exportFilter(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): return "无法打开数据库：\(m)"
        case .sql(let m): return "数据库错误：\(m)"
        case .exportFilter(let m): return m
        }
    }
}

final class Database {
    static let schemaVersion = 2

    static let baseColumns = [
        "epmc_id", "pmid", "doi", "source", "pmcid",
        "title", "abstract", "pub_year", "author_string",
        "journal_title", "first_publication_date", "query_search_term",
        "journal_info_json", "keyword_list_json",
        "title_zh", "abstract_zh",
    ]

    private let db: OpaquePointer
    let path: URL

    // ── 打开 + 迁移 ────────────────────────────────────────────────────────────

    init(path: URL, config: AppConfig? = nil) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK, let handle else {
            throw DBError.open(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
        }
        self.db = handle
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try runMigrations()
        if let config { try ensureDynamicColumns(config) }
    }

    deinit { sqlite3_close(db) }

    // ── 低层执行 ──────────────────────────────────────────────────────────────

    private func errmsg() -> String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw DBError.sql("\(errmsg())  (SQL: \(sql.prefix(120)))")
        }
    }

    /// 执行一条带绑定参数的语句（非查询），返回受影响行数。
    /// Internal so the focused Database extensions can share one execution path.
    @discardableResult
    func run(_ sql: String, _ binds: [DBValue] = []) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sql("\(errmsg())  (SQL: \(sql.prefix(120)))")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.sql("\(errmsg())  (SQL: \(sql.prefix(120)))")
        }
        return Int(sqlite3_changes(db))
    }

    /// 查询，返回有序列名 + 每行的值字典。
    func query(_ sql: String, _ binds: [DBValue] = []) throws -> (columns: [String], rows: [[String: DBValue]]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sql("\(errmsg())  (SQL: \(sql.prefix(120)))")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        let colCount = Int(sqlite3_column_count(stmt))
        let names = (0..<colCount).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        var rows: [[String: DBValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: DBValue] = [:]
            for i in 0..<colCount {
                row[names[i]] = columnValue(stmt, Int32(i))
            }
            rows.append(row)
        }
        return (names, rows)
    }

    func scalarInt(_ sql: String, _ binds: [DBValue] = []) throws -> Int {
        let r = try query(sql, binds)
        return r.rows.first?.values.first?.intValue ?? 0
    }

    private func bind(_ stmt: OpaquePointer?, _ binds: [DBValue]) {
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .null: sqlite3_bind_null(stmt, idx)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            }
        }
    }

    private func columnValue(_ stmt: OpaquePointer?, _ i: Int32) -> DBValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .int(Int(sqlite3_column_int64(stmt, i)))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
        default:
            if let c = sqlite3_column_text(stmt, i) { return .text(String(cString: c)) }
            return .null
        }
    }

    func existingColumns() throws -> [String] {
        try query("PRAGMA table_info(articles)").rows.compactMap { $0["name"]?.stringValue }
    }

    // Shared by the focused extensions below; it was private in the monolithic file.
    func hasColumn(_ c: String) throws -> Bool { Set(try existingColumns()).contains(c) }

    // ── 迁移 ──────────────────────────────────────────────────────────────────

    private func userVersion() throws -> Int { try scalarInt("PRAGMA user_version") }

    private func tableExists() throws -> Bool {
        try !query("SELECT name FROM sqlite_master WHERE type='table' AND name='articles'").rows.isEmpty
    }

    private func runMigrations() throws {
        if try userVersion() >= Database.schemaVersion { return }
        if try !tableExists() {
            try exec(Self.createTableSQL + Self.createIndexSQL)
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
            return
        }
        // 旧库（v0/v1）：非破坏性地提升版本号，缺失的动态列稍后由 ensureDynamicColumns 补齐。
        // 完整的就地列裁剪迁移不在此处实现；历史库可通过 migrate 诊断命令导入新库。
        try exec("PRAGMA user_version = \(Self.schemaVersion)")
    }

    // ── Schema SQL ────────────────────────────────────────────────────────────

    private static let createTableSQL = """
    CREATE TABLE IF NOT EXISTS articles (
        epmc_id                TEXT PRIMARY KEY,
        pmid                   TEXT,
        doi                    TEXT,
        source                 TEXT,
        pmcid                  TEXT,
        title                  TEXT,
        abstract               TEXT,
        pub_year               INTEGER,
        author_string          TEXT,
        journal_title          TEXT,
        first_publication_date TEXT,
        query_search_term      TEXT,
        journal_info_json      TEXT,
        keyword_list_json      TEXT,
        title_zh               TEXT,
        abstract_zh            TEXT,
        CONSTRAINT uq_pmid UNIQUE (pmid),
        CONSTRAINT uq_doi  UNIQUE (doi)
    );
    """

    private static let createIndexSQL = """
    CREATE INDEX IF NOT EXISTS idx_pub_year ON articles(pub_year);
    CREATE INDEX IF NOT EXISTS idx_journal  ON articles(journal_title);
    """
}

import Foundation
import SQLite3

// SQLite 数据层，对应 Python 参考的 db.py（schema v2、动态列、去重插入、统计等）。
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

    // ── 打开 + 迁移 + 动态列 ──────────────────────────────────────────────────

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
    @discardableResult
    private func run(_ sql: String, _ binds: [DBValue] = []) throws -> Int {
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
        // 完整的列裁剪迁移暂不在原生版实现（可继续用 Python CLI 处理历史库）。
        try exec("PRAGMA user_version = \(Self.schemaVersion)")
    }

    // ── 动态列 ────────────────────────────────────────────────────────────────

    func ensureDynamicColumns(_ cfg: AppConfig) throws {
        var existing = Set(try existingColumns())
        for q in cfg.classify.questions {
            for suffix in ["_ans", "_rea"] {
                let col = "\(q.id)\(suffix)"
                if !existing.contains(col) {
                    try exec("ALTER TABLE articles ADD COLUMN \(col) TEXT")
                    existing.insert(col)
                }
            }
        }
        for col in cfg.schema.customColumns where !existing.contains(col) {
            try exec("ALTER TABLE articles ADD COLUMN \(col) TEXT")
            existing.insert(col)
        }
        if existing.contains("include") {
            try exec("CREATE INDEX IF NOT EXISTS idx_include ON articles(include)")
        }
        for q in cfg.classify.questions where existing.contains("\(q.id)_ans") {
            try exec("CREATE INDEX IF NOT EXISTS idx_\(q.id)_ans ON articles(\(q.id)_ans)")
        }
    }

    // ── 插入（INSERT OR IGNORE 去重）──────────────────────────────────────────

    @discardableResult
    func insertArticles(_ articles: [[String: DBValue]]) throws -> (inserted: Int, skipped: Int) {
        guard let first = articles.first else { return (0, 0) }
        let existing = Set(try existingColumns())
        // 按 baseColumns 的固定顺序取交集，保证 SQL 列序稳定。
        let cols = Self.baseColumns.filter { existing.contains($0) && first.keys.contains($0) }
        guard !cols.isEmpty else { return (0, 0) }
        let placeholders = cols.map { _ in "?" }.joined(separator: ", ")
        let sql = "INSERT OR IGNORE INTO articles (\(cols.joined(separator: ", "))) VALUES (\(placeholders))"

        try exec("BEGIN")
        var inserted = 0, skipped = 0
        do {
            for art in articles {
                let changes = try run(sql, cols.map { art[$0] ?? .null })
                if changes > 0 { inserted += 1 } else { skipped += 1 }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return (inserted, skipped)
    }

    // ── 翻译查询 ──────────────────────────────────────────────────────────────

    func fetchPendingTranslations() throws -> [(epmcID: String, title: String)] {
        let r = try query("SELECT epmc_id, title FROM articles WHERE title IS NOT NULL AND title_zh IS NULL")
        return r.rows.compactMap {
            guard let id = $0["epmc_id"]?.stringValue, let title = $0["title"]?.stringValue else { return nil }
            return (id, title)
        }
    }

    func updateTranslations(_ updates: [(epmcID: String, titleZh: String?)]) throws {
        try exec("BEGIN")
        do {
            for u in updates {
                _ = try run(
                    "UPDATE articles SET title_zh = COALESCE(?, title_zh) WHERE epmc_id = ?",
                    [u.titleZh.map { DBValue.text($0) } ?? .null, .text(u.epmcID)])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK"); throw error
        }
    }

    // ── 分类查询 / 回写 ───────────────────────────────────────────────────────

    func fetchPendingClassification(_ questions: [Question]) throws -> [(epmcID: String, title: String, abstract: String)] {
        guard !questions.isEmpty else { return [] }
        let nullChecks = questions.map { "\($0.id)_ans IS NULL" }.joined(separator: " OR ")
        let sql = "SELECT epmc_id, title, abstract FROM articles WHERE (\(nullChecks)) AND (title IS NOT NULL OR abstract IS NOT NULL)"
        return try query(sql).rows.compactMap {
            guard let id = $0["epmc_id"]?.stringValue else { return nil }
            return (id, $0["title"]?.stringValue ?? "", $0["abstract"]?.stringValue ?? "")
        }
    }

    /// 写一批分类结果（COALESCE 保护已有值）。results: epmcID -> [qid: (answer, reason)]。
    func writeClassification(_ batch: [(epmcID: String, results: [String: (answer: String, reason: String)])]) throws {
        try exec("BEGIN")
        do {
            for item in batch where !item.results.isEmpty {
                var setParts: [String] = []
                var params: [DBValue] = []
                for (qid, ar) in item.results {
                    setParts.append("\(qid)_ans = COALESCE(?, \(qid)_ans)")
                    setParts.append("\(qid)_rea = COALESCE(?, \(qid)_rea)")
                    params.append(.text(ar.answer))
                    params.append(.text(ar.reason))
                }
                params.append(.text(item.epmcID))
                _ = try run("UPDATE articles SET \(setParts.joined(separator: ", ")) WHERE epmc_id = ?", params)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK"); throw error
        }
    }

    // ── 复筛回写 ──────────────────────────────────────────────────────────────

    @discardableResult
    func applyReview(rows: [[String: String?]], annotationColumns: [String]) throws -> (updated: Int, unmatched: Int) {
        let existing = Set(try existingColumns())
        let cols = annotationColumns.filter { existing.contains($0) }
        guard !cols.isEmpty else { return (0, 0) }

        var updated = 0, unmatched = 0
        try exec("BEGIN")
        do {
            for row in rows {
                let setItems = cols.compactMap { c -> (String, String)? in
                    if let v = row[c], let v { return (c, v) }
                    return nil
                }
                if setItems.isEmpty { continue }
                var keyCol: String?, keyVal: String?
                for k in ["epmc_id", "pmid", "doi"] {
                    if let v = row[k], let v, !v.isEmpty { keyCol = k; keyVal = v; break }
                }
                guard let keyCol, let keyVal else { unmatched += 1; continue }
                let setClause = setItems.map { "\($0.0) = ?" }.joined(separator: ", ")
                let params = setItems.map { DBValue.text($0.1) } + [.text(keyVal)]
                let changes = try run("UPDATE articles SET \(setClause) WHERE \(keyCol) = ?", params)
                if changes > 0 { updated += 1 } else { unmatched += 1 }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK"); throw error
        }
        return (updated, unmatched)
    }

    // ── 导出查询 ──────────────────────────────────────────────────────────────

    func fetchForExport(filterMode: String) throws -> (columns: [String], rows: [[String: DBValue]]) {
        let whereClause: String
        switch filterMode {
        case "pending":
            guard try existingColumns().contains("include") else {
                throw DBError.exportFilter("导出筛选 'pending' 需要 include 列，但当前数据库没有该列。请改用 all 或在标注列中保留 include。")
            }
            whereClause = "include IS NULL"
        case "all":
            whereClause = "1=1"
        default:
            whereClause = filterMode
        }
        return try query("SELECT * FROM articles WHERE \(whereClause) ORDER BY pub_year DESC")
    }

    // ── 统计 ──────────────────────────────────────────────────────────────────

    func stats(questions: [Question]) throws -> [String: Int] {
        var out: [String: Int] = [:]
        out["total"] = try scalarInt("SELECT COUNT(*) FROM articles")
        out["pending_translation"] = try scalarInt(
            "SELECT COUNT(*) FROM articles WHERE title IS NOT NULL AND title_zh IS NULL")

        let cols = Set(try existingColumns())
        for q in questions where cols.contains("\(q.id)_ans") {
            let a = "\(q.id)_ans"
            out["pending_\(q.id)"] = try scalarInt("SELECT COUNT(*) FROM articles WHERE \(a) IS NULL")
            out["\(q.id)_yes"] = try scalarInt("SELECT COUNT(*) FROM articles WHERE \(a) = '是'")
            out["\(q.id)_no"] = try scalarInt("SELECT COUNT(*) FROM articles WHERE \(a) = '否'")
            out["\(q.id)_other"] = try scalarInt(
                "SELECT COUNT(*) FROM articles WHERE \(a) IS NOT NULL AND \(a) NOT IN ('是', '否')")
        }
        if cols.contains("include") {
            out["reviewed_yes"] = try scalarInt("SELECT COUNT(*) FROM articles WHERE include = 'yes'")
            out["reviewed_no"] = try scalarInt("SELECT COUNT(*) FROM articles WHERE include = 'no'")
        }
        return out
    }

    func backup() throws -> URL {
        let bak = path.deletingPathExtension().appendingPathExtension("db.bak")
        try? FileManager.default.removeItem(at: bak)
        try FileManager.default.copyItem(at: path, to: bak)
        return bak
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

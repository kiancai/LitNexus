import Foundation

extension Database {
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
        try writeQuestionMeta(cfg.classify.questions)
        // 检索渠道关联表：一篇文章 × 命中它的每个检索式（期刊/关键词）。按字面串归集。
        try exec("""
            CREATE TABLE IF NOT EXISTS article_terms (
                epmc_id TEXT NOT NULL,
                term    TEXT NOT NULL,
                kind    TEXT NOT NULL,
                PRIMARY KEY (epmc_id, term)
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_terms_term ON article_terms(term)")
    }

    /// 把问题定义写进库内 litnexus_questions 表，使 .db 自描述（导入时可按文本对齐）。
    ///
    /// `archived` 是历史语义的一部分，不能只留在 TOML：单独导出的 .db 也要能说明
    /// 某列是否已退出当前工作流。旧项目的三列元数据表会在这里非破坏性补列。
    func writeQuestionMeta(_ questions: [Question]) throws {
        try ensureQuestionMetaSchema()
        try exec("DELETE FROM litnexus_questions")
        for q in questions {
            _ = try run(
                "INSERT INTO litnexus_questions (id, nickname, text, archived, classify_enabled, classify_after_rowid) VALUES (?, ?, ?, ?, ?, ?)",
                [
                    .text(q.id), .text(q.nickname), .text(q.text),
                    .int(q.archived ? 1 : 0), .int(q.classify ? 1 : 0),
                    q.classifyAfterRowID.map(DBValue.int) ?? .null,
                ]
            )
        }
    }

    /// 在任何破坏性问题删除前创建一致性 SQLite 备份。不同于直接复制 WAL 主文件，
    /// `VACUUM INTO` 会把当前数据库快照完整写入独立文件。
    func backupBeforeQuestionDeletion(_ qid: String) throws -> URL {
        guard Identifier.isValid(qid) else { throw DBError.sql("非法问题标识：\(qid)") }
        let stem = path.deletingPathExtension().lastPathComponent
        let millis = Int(Date().timeIntervalSince1970 * 1_000)
        let nonce = UUID().uuidString.prefix(8).lowercased()
        let backup = path.deletingLastPathComponent().appendingPathComponent(
            "\(stem).before-delete-\(qid)-\(millis)-\(nonce).db")
        _ = try run("VACUUM INTO ?", [.text(backup.path)])
        return backup
    }

    /// 永久删除某问题：连同 {qid}_ans / {qid}_rea 两列及其数据一并 DROP。
    /// 这一步在单个 SQLite 事务里完成；调用方必须已经先调用
    /// `backupBeforeQuestionDeletion(_:)`，并负责在失败时恢复任何已写出的配置变更。
    func dropQuestionColumns(_ qid: String) throws {
        guard Identifier.isValid(qid) else { throw DBError.sql("非法问题标识：\(qid)") }
        try exec("BEGIN IMMEDIATE")
        do {
            // 先去掉依赖该列的索引，否则 DROP COLUMN 会报错。
            try exec("DROP INDEX IF EXISTS idx_\(qid)_ans")
            let existing = Set(try existingColumns())
            for suffix in ["_ans", "_rea"] {
                let col = "\(qid)\(suffix)"
                if existing.contains(col) { try exec("ALTER TABLE articles DROP COLUMN \(col)") }
            }
            try ensureQuestionMetaSchema()
            _ = try run("DELETE FROM litnexus_questions WHERE id = ?", [.text(qid)])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func ensureQuestionMetaSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS litnexus_questions (
                id TEXT PRIMARY KEY,
                nickname TEXT,
                text TEXT,
                archived INTEGER NOT NULL DEFAULT 0,
                classify_enabled INTEGER NOT NULL DEFAULT 1,
                classify_after_rowid INTEGER
            )
            """)
        let existing = Set(try query("PRAGMA table_info(litnexus_questions)").rows.compactMap {
            $0["name"]?.stringValue
        })
        if !existing.contains("archived") {
            try exec("ALTER TABLE litnexus_questions ADD COLUMN archived INTEGER NOT NULL DEFAULT 0")
        }
        if !existing.contains("classify_enabled") {
            try exec("ALTER TABLE litnexus_questions ADD COLUMN classify_enabled INTEGER NOT NULL DEFAULT 1")
        }
        if !existing.contains("classify_after_rowid") {
            try exec("ALTER TABLE litnexus_questions ADD COLUMN classify_after_rowid INTEGER")
        }
    }
}

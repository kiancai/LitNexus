import Foundation

extension Database {
    // ── 导出查询 ──────────────────────────────────────────────────────────────

    func fetchForExport(filterMode: String) throws -> (columns: [String], rows: [[String: DBValue]]) {
        let needsInclude = ["pending", "included", "excluded"]
        if needsInclude.contains(filterMode), try !existingColumns().contains("include") {
            throw DBError.exportFilter("该导出范围需要 include 列，但当前数据库没有。请改用「全部」或在标注列中保留 include。")
        }
        let whereClause: String
        switch filterMode {
        case "pending":  whereClause = "include IS NULL"     // 待复筛
        case "included": whereClause = "include = 'yes'"     // 已纳入
        case "excluded": whereClause = "include = 'no'"      // 已排除
        case "all":      whereClause = "1=1"
        default:         whereClause = filterMode
        }
        return try query("SELECT * FROM articles WHERE \(whereClause) ORDER BY pub_year DESC")
    }

    func backup() throws -> URL {
        let bak = path.deletingPathExtension().appendingPathExtension("db.bak")
        try? FileManager.default.removeItem(at: bak)
        // 数据库在 WAL 模式下运行，直接复制主文件可能遗漏尚在 WAL 中的已提交页。
        // VACUUM INTO 生成的是同一时刻、可独立打开的 SQLite 快照。
        _ = try run("VACUUM INTO ?", [.text(bak.path)])
        return bak
    }

    // ── 数据库整体导出 / 导入 / 清空 ─────────────────────────────────────────────

    /// 导出为一份干净的独立 .db（VACUUM INTO 会落盘所有已提交数据，无需 WAL 边车文件）。
    func exportTo(_ dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.removeItem(at: dest.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: dest.appendingPathExtension("shm"))
        _ = try run("VACUUM INTO ?", [.text(dest.path)])
    }

    /// 导入冲突策略。
    enum ImportStrategy {
        case skipExisting   // 已有行（同 pmid/doi）原样保留，只插入全新行（默认，最安全）
        case fillEmpty      // 已有行：仅把当前为 NULL 的字段用源值补上；其余保留。再插入全新行
    }

    /// 源库的问题信息（用于导入前的人工对齐）。text/nickname 仅当源库自带 litnexus_questions 表时可知。
    struct SourceQuestionInfo { let id: String; let nickname: String?; let text: String? }
    struct ImportInspection { let sourceQuestions: [SourceQuestionInfo]; let total: Int }

    /// 检查源 .db：列出它的问题列（及自描述文本，若有）与总行数，供 UI 做对齐。
    func inspectImport(_ source: URL) throws -> ImportInspection {
        _ = try run("ATTACH DATABASE ? AS src", [.text(source.path)])
        defer { try? exec("DETACH DATABASE src") }
        guard try !query("SELECT name FROM src.sqlite_master WHERE type='table' AND name='articles'").rows.isEmpty else {
            throw DBError.sql("源数据库中没有 articles 表，无法导入。")
        }
        let srcCols = try query("PRAGMA src.table_info(articles)").rows.compactMap { $0["name"]?.stringValue }
        let qids = srcCols.filter { $0.hasSuffix("_ans") }.map { String($0.dropLast(4)) }

        var meta: [String: (String?, String?)] = [:]
        if try !query("SELECT name FROM src.sqlite_master WHERE type='table' AND name='litnexus_questions'").rows.isEmpty {
            for row in try query("SELECT id, nickname, text FROM src.litnexus_questions").rows {
                if let id = row["id"]?.stringValue { meta[id] = (row["nickname"]?.stringValue, row["text"]?.stringValue) }
            }
        }
        let questions = qids.map { SourceQuestionInfo(id: $0, nickname: meta[$0]?.0, text: meta[$0]?.1) }
        let total = try scalarInt("SELECT COUNT(*) FROM src.articles")
        return ImportInspection(sourceQuestions: questions, total: total)
    }

    /// 从另一份 .db 导入：通用列（非问题列）按列名自动对齐；问题列按 questionColumnPairs 显式映射。
    /// questionColumnPairs 为空表示不导入任何问题列。返回 (新增, 既有, 源库总数)。
    @discardableResult
    func importFromDatabase(_ source: URL, strategy: ImportStrategy = .skipExisting,
                            questionColumnPairs: [(dest: String, src: String)]? = nil)
        throws -> (inserted: Int, skipped: Int, total: Int) {
        _ = try run("ATTACH DATABASE ? AS src", [.text(source.path)])
        defer { try? exec("DETACH DATABASE src") }
        guard try !query("SELECT name FROM src.sqlite_master WHERE type='table' AND name='articles'").rows.isEmpty else {
            throw DBError.sql("源数据库中没有 articles 表，无法导入。")
        }
        let srcCols = try query("PRAGMA src.table_info(articles)").rows.compactMap { $0["name"]?.stringValue }
        let dstCols = try existingColumns()
        let srcLower = Set(srcCols.map { $0.lowercased() })
        func isQ(_ c: String) -> Bool { c.hasSuffix("_ans") || c.hasSuffix("_rea") }

        // 通用列：两边都有、且不是问题列。questionColumnPairs == nil 表示「全自动对齐」(含问题列，供迁移工具用)。
        let universal: [(dest: String, src: String)]
        if questionColumnPairs == nil {
            universal = dstCols.filter { srcLower.contains($0.lowercased()) }.map { (dest: $0, src: $0) }
        } else {
            universal = dstCols.filter { !isQ($0) && srcLower.contains($0.lowercased()) }.map { (dest: $0, src: $0) }
        }
        var pairs = universal + (questionColumnPairs ?? [])
        guard pairs.contains(where: { $0.dest.lowercased() == "epmc_id" }) else {
            throw DBError.sql("源库缺少 epmc_id 主键，无法导入。")
        }
        // 去重（避免某列既在通用又在映射里）
        var seen = Set<String>()
        pairs = pairs.filter { seen.insert($0.dest.lowercased()).inserted }

        let total = try scalarInt("SELECT COUNT(*) FROM src.articles")
        let before = try scalarInt("SELECT COUNT(*) FROM main.articles")

        if strategy == .fillEmpty {
            let setClause = pairs.filter { $0.dest.lowercased() != "epmc_id" }
                .map { "\($0.dest) = COALESCE(m.\($0.dest), s.\($0.src))" }.joined(separator: ", ")
            if !setClause.isEmpty {
                try exec("UPDATE main.articles AS m SET \(setClause) FROM src.articles AS s WHERE s.epmc_id = m.epmc_id")
            }
        }
        let destList = pairs.map { $0.dest }.joined(separator: ", ")
        let srcList = pairs.map { $0.src }.joined(separator: ", ")
        try exec("INSERT OR IGNORE INTO main.articles (\(destList)) SELECT \(srcList) FROM src.articles")
        let after = try scalarInt("SELECT COUNT(*) FROM main.articles")
        let inserted = after - before
        return (inserted, total - inserted, total)
    }

    /// 清空所有文章（保留表结构与动态列），并回收磁盘空间。
    func clearArticles() throws {
        try exec("DELETE FROM articles")
        try exec("VACUUM")
    }
}

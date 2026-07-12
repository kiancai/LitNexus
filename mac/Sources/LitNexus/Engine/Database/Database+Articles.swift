import Foundation

/// 人工复筛预检读取到的当前标注。专门保持在 articles 的稳定主键 epmc_id 上；
/// 不允许再退回 pmid/doi 匹配。
struct ReviewedCSVStoredValues {
    let include: String?
    let tags: String?
}

struct ReviewedCSVWriteOutcome {
    let updatedRows: Int
    let updatedFields: Int
    let unmatchedRows: Int
    let protectedRows: Int
}

extension Database {
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

    /// 待翻译：textColumn 非空但 zhColumn 仍为空。默认翻译标题（title → title_zh）。
    func fetchPendingTranslations(textColumn: String = "title", zhColumn: String = "title_zh")
        throws -> [(epmcID: String, title: String)] {
        let r = try query("SELECT epmc_id, \(textColumn) AS src FROM articles WHERE \(textColumn) IS NOT NULL AND \(textColumn) != '' AND \(zhColumn) IS NULL")
        return r.rows.compactMap {
            guard let id = $0["epmc_id"]?.stringValue, let s = $0["src"]?.stringValue else { return nil }
            return (id, s)
        }
    }

    func updateTranslations(_ updates: [(epmcID: String, titleZh: String?)], column: String = "title_zh") throws {
        try exec("BEGIN")
        do {
            for u in updates {
                _ = try run(
                    "UPDATE articles SET \(column) = COALESCE(?, \(column)) WHERE epmc_id = ?",
                    [u.titleZh.map { DBValue.text($0) } ?? .null, .text(u.epmcID)])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK"); throw error
        }
    }

    // ── 分类查询 / 回写 ───────────────────────────────────────────────────────

    /// 当前 articles 动态列方案下的分类待办。
    /// 调用方必须把具有不同 `classifyAfterRowID` 的问题分组后再调用；否则同一篇文章
    /// 会面对不该适用的问题。AIClient 已按此规则分组。
    func fetchPendingClassification(_ questions: [Question]) throws -> [(epmcID: String, title: String, abstract: String)] {
        guard !questions.isEmpty else { return [] }
        let scopeKeys = Set(questions.map(\.classificationScopeKey))
        guard scopeKeys.count == 1 else {
            throw DBError.sql("分类问题的适用范围不同，必须分别处理。")
        }
        let valid = questions.filter { Identifier.isValid($0.id) && (try? hasColumn("\($0.id)_ans")) == true }
        guard !valid.isEmpty else { return [] }
        let nullChecks = valid.map { "\($0.id)_ans IS NULL" }.joined(separator: " OR ")
        var sql = "SELECT epmc_id, title, abstract FROM articles WHERE (\(nullChecks)) AND (title IS NOT NULL OR abstract IS NOT NULL)"
        var binds: [DBValue] = []
        if let after = valid[0].classifyAfterRowID {
            sql += " AND rowid > ?"
            binds.append(.int(max(0, after)))
        }
        return try query(sql, binds).rows.compactMap {
            guard let id = $0["epmc_id"]?.stringValue else { return nil }
            return (id, $0["title"]?.stringValue ?? "", $0["abstract"]?.stringValue ?? "")
        }
    }

    /// 记录新问题的“未来文章”边界。articles 是追加式的：之后成功合并的记录 rowid
    /// 会大于该值，因此旧库无需全表写入 created_at 也能得到稳定的生效范围。
    func currentArticleRowID() throws -> Int {
        try scalarInt("SELECT COALESCE(MAX(rowid), 0) FROM articles")
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

    /// 为 CSV 预检批量读取当前人工标注。按 SQLite 绑定参数上限分块，避免大 CSV
    /// 导入时构造超长 IN 语句。
    func reviewValues(forEPMCIDs epmcIDs: [String]) throws -> [String: ReviewedCSVStoredValues] {
        guard !epmcIDs.isEmpty else { return [:] }
        let existing = Set(try existingColumns())
        guard existing.contains("include"), existing.contains("tags") else {
            throw DBError.exportFilter("当前数据库缺少 include 或 tags 标注列，无法导入复筛 CSV。")
        }

        let ids = Array(Set(epmcIDs))
        let chunkSize = 900  // 保守低于 SQLite 默认的 999 个绑定变量限制。
        var out: [String: ReviewedCSVStoredValues] = [:]
        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let end = min(start + chunkSize, ids.count)
            let chunk = Array(ids[start..<end])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try query(
                "SELECT epmc_id, include, tags FROM articles WHERE epmc_id IN (\(placeholders))",
                chunk.map(DBValue.text)).rows
            for row in rows {
                guard let id = row["epmc_id"]?.stringValue else { continue }
                out[id] = ReviewedCSVStoredValues(
                    include: row["include"]?.stringValue,
                    tags: row["tags"]?.stringValue)
            }
        }
        return out
    }

    /// 将已经通过预检的复筛标注写回。没有 allowOverwrite 时，每个字段在 SQL 层
    /// 仍附带“当前为空”的条件，防止调用方绕开预检而覆盖已有的人工判断。
    func applyReviewedCSVUpdates(_ updates: [ReviewedCSVRowUpdate],
                                 allowOverwrite: Bool) throws -> ReviewedCSVWriteOutcome {
        guard !updates.isEmpty else {
            return ReviewedCSVWriteOutcome(updatedRows: 0, updatedFields: 0,
                                           unmatchedRows: 0, protectedRows: 0)
        }
        let existing = Set(try existingColumns())
        guard existing.contains("include"), existing.contains("tags") else {
            throw DBError.exportFilter("当前数据库缺少 include 或 tags 标注列，无法写入复筛 CSV。")
        }

        // 预检和写入之间再次确认文章还存在，避免把“0 行更新”误报为已保护字段。
        let current = try reviewValues(forEPMCIDs: updates.map(\.epmcID))
        var updatedIDs = Set<String>()
        var protectedIDs = Set<String>()
        var unmatchedIDs = Set<String>()
        var updatedFields = 0

        try exec("BEGIN")
        do {
            for update in updates {
                guard current[update.epmcID] != nil else {
                    unmatchedIDs.insert(update.epmcID)
                    continue
                }

                if let include = update.include {
                    let sql: String
                    if allowOverwrite {
                        sql = "UPDATE articles SET include = ? WHERE epmc_id = ?"
                    } else {
                        sql = "UPDATE articles SET include = ? WHERE epmc_id = ? AND (include IS NULL OR TRIM(include) = '')"
                    }
                    let changed = try run(sql, [.text(include), .text(update.epmcID)])
                    if changed > 0 {
                        updatedIDs.insert(update.epmcID)
                        updatedFields += 1
                    } else if !allowOverwrite {
                        protectedIDs.insert(update.epmcID)
                    }
                }

                if let tags = update.tags {
                    let sql: String
                    if allowOverwrite {
                        sql = "UPDATE articles SET tags = ? WHERE epmc_id = ?"
                    } else {
                        sql = "UPDATE articles SET tags = ? WHERE epmc_id = ? AND (tags IS NULL OR TRIM(tags) = '')"
                    }
                    let changed = try run(sql, [.text(tags), .text(update.epmcID)])
                    if changed > 0 {
                        updatedIDs.insert(update.epmcID)
                        updatedFields += 1
                    } else if !allowOverwrite {
                        protectedIDs.insert(update.epmcID)
                    }
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return ReviewedCSVWriteOutcome(updatedRows: updatedIDs.count, updatedFields: updatedFields,
                                       unmatchedRows: unmatchedIDs.count, protectedRows: protectedIDs.count)
    }

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
}

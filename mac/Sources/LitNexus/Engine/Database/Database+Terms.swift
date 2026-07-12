import Foundation

extension Database {
    // ── 检索渠道（article_terms）─────────────────────────────────────────────────

    /// 累积一批「文章↔检索式」命中（INSERT OR IGNORE，重复命中不计两次）。
    func insertArticleTerms(_ pairs: [(epmcID: String, term: String, kind: String)]) throws {
        guard !pairs.isEmpty else { return }
        try exec("BEGIN")
        do {
            for p in pairs where !p.epmcID.isEmpty && !p.term.isEmpty {
                _ = try run("INSERT OR IGNORE INTO article_terms (epmc_id, term, kind) VALUES (?, ?, ?)",
                            [.text(p.epmcID), .text(p.term), .text(p.kind)])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK"); throw error
        }
    }

    /// 清空整张渠道表（重建前用）。
    func clearArticleTerms() throws { try exec("DELETE FROM article_terms") }

    func articleTermsCount() throws -> Int { try scalarInt("SELECT COUNT(*) FROM article_terms") }

    /// 各关键词检索式的产出：命中文章数 / 其中纳入数 / 独有纳入（仅此检索式命中、别的都没命中）。
    func keywordTermStats() throws -> [(term: String, total: Int, included: Int, uniqueIncluded: Int)] {
        guard try hasColumn("include") else { return [] }
        let r = try query("""
            SELECT t.term AS term,
                   COUNT(*) AS total,
                   SUM(CASE WHEN a.include = 'yes' THEN 1 ELSE 0 END) AS inc,
                   SUM(CASE WHEN a.include = 'yes'
                             AND (SELECT COUNT(*) FROM article_terms t2 WHERE t2.epmc_id = t.epmc_id) = 1
                            THEN 1 ELSE 0 END) AS uniq
            FROM article_terms t
            JOIN articles a ON a.epmc_id = t.epmc_id
            WHERE t.kind = 'keyword'
            GROUP BY t.term
            ORDER BY total DESC, term COLLATE NOCASE ASC
            """)
        return r.rows.compactMap { row in
            guard let term = row["term"]?.stringValue else { return nil }
            return (term, row["total"]?.intValue ?? 0, row["inc"]?.intValue ?? 0, row["uniq"]?.intValue ?? 0)
        }
    }
}

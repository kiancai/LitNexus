import Foundation

// EPMC JSON → DB 字段映射、JSONL 读取、CSV 导出/导回。对应 Python 参考的 io.py。

enum ArticleIO {
    /// 将 EPMC API 原始 JSON 映射到 DB schema 字段。
    static func parseArticle(_ raw: [String: Any]) -> [String: DBValue] {
        func nonEmptyString(_ key: String) -> DBValue {
            if let s = raw[key] as? String, !s.isEmpty { return .text(s) }
            return .null
        }

        // pub_year：可能是字符串或数字
        var pubYear: DBValue = .null
        if let n = raw["pubYear"] as? Int { pubYear = .int(n) }
        else if let s = raw["pubYear"] as? String, let n = Int(s) { pubYear = .int(n) }

        // journal_title
        var journalTitle: DBValue = .null
        let journalInfo = raw["journalInfo"] as? [String: Any]
        if let journal = journalInfo?["journal"] as? [String: Any], let t = journal["title"] as? String {
            journalTitle = .text(t)
        }

        // query_search_term（兼容期刊脚本注入的 query_journal_name）
        var queryTerm: DBValue = .null
        if let s = raw["query_search_term"] as? String, !s.isEmpty { queryTerm = .text(s) }
        else if let s = raw["query_journal_name"] as? String, !s.isEmpty { queryTerm = .text(s) }

        func jsonColumn(_ value: Any?) -> DBValue {
            guard let value, JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let s = String(data: data, encoding: .utf8) else { return .null }
            return .text(s)
        }

        var record: [String: DBValue] = [
            "epmc_id": nonEmptyString("id"),
            "pmid": nonEmptyString("pmid"),
            "doi": nonEmptyString("doi"),
            "source": nonEmptyString("source"),
            "pmcid": nonEmptyString("pmcid"),
            "title": nonEmptyString("title"),
            "abstract": nonEmptyString("abstractText"),
            "pub_year": pubYear,
            "author_string": nonEmptyString("authorString"),
            "journal_title": journalTitle,
            "first_publication_date": nonEmptyString("firstPublicationDate"),
            "query_search_term": queryTerm,
            "journal_info_json": (journalInfo?.isEmpty == false) ? jsonColumn(journalInfo) : .null,
            "keyword_list_json": jsonColumn(raw["keywordList"]),
        ]
        // id 为空时 epmc_id 为 null，调用方据此计入 errors
        if case .null = record["epmc_id"]! { record["epmc_id"] = .null }
        return record
    }

    /// 逐行读取 JSONL，跳过空行和解析错误行。
    static func iterJSONL(_ path: URL) -> [[String: Any]] {
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                out.append(obj)
            }
        }
        return out
    }

    /// 导出查询结果到 CSV（utf-8-sig，排除 excludeColumns 列）。返回行数。
    @discardableResult
    static func exportCSV(columns: [String], rows: [[String: DBValue]], to output: URL,
                          excludeColumns: [String]) throws -> Int {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let exclude = Set(excludeColumns)
        let keep = columns.filter { !exclude.contains($0) }

        func cell(_ v: DBValue?) -> String {
            switch v {
            case .text(let s): return s
            case .int(let n): return String(n)
            case .double(let d): return String(d)
            case .null, .none: return ""
            }
        }

        var lines: [[String]] = [keep]
        for row in rows {
            lines.append(keep.map { cell(row[$0]) })
        }
        let csv = "\u{FEFF}" + CSV.write(lines)
        try csv.write(to: output, atomically: true, encoding: .utf8)
        return rows.count
    }

    /// 将 None / 空 / "N/A" 标准化为 nil。
    static func normalizeValue(_ v: String?) -> String? {
        guard let v else { return nil }
        let s = v.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.uppercased() == "N/A" { return nil }
        return s
    }

    /// 从复筛 CSV 读取标注并写回数据库。返回 (updated, unmatched, total)。
    static func importReviewedCSV(_ db: Database, csvPath: URL, annotationColumns: [String]) throws
        -> (updated: Int, unmatched: Int, total: Int) {
        let text = try String(contentsOf: csvPath, encoding: .utf8)
        let (header, rawRows) = CSV.parseWithHeader(text)
        let total = rawRows.count
        if total == 0 { return (0, 0, 0) }

        let keyCols = ["epmc_id", "pmid", "doi"].filter { header.contains($0) }
        guard !keyCols.isEmpty else {
            throw DBError.exportFilter("CSV 缺少匹配键列（需要 epmc_id / pmid / doi 之一）。")
        }
        let annCols = annotationColumns.filter { header.contains($0) }
        guard !annCols.isEmpty else {
            throw DBError.exportFilter("CSV 中没有可写回的标注列（期望之一：\(annotationColumns.joined(separator: ", "))）。")
        }

        var rows: [[String: String?]] = []
        for r in rawRows {
            var row: [String: String?] = [:]
            for k in keyCols {
                if let v = normalizeValue(r[k]) { row[k] = v }
            }
            for c in annCols {
                var v = normalizeValue(r[c])
                if c == "include", let vv = v { v = vv.lowercased() }
                row[c] = v
            }
            rows.append(row)
        }

        let (updated, unmatched) = try db.applyReview(rows: rows, annotationColumns: annotationColumns)
        return (updated, unmatched, total)
    }
}

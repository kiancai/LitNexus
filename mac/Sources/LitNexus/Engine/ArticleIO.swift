import Foundation

// EPMC JSON → DB 字段映射、JSONL 读取、CSV 导出/导回。

// MARK: - 人工复筛 CSV 的安全导入契约

/// 复筛 CSV 预检中的问题等级。错误会阻止写库；警告只说明某些行会被跳过。
enum ReviewedCSVImportSeverity: String, Hashable {
    case warning
    case error
}

/// 预检问题的稳定类型。UI 可以据此分组展示，而不需要解析本地化文案。
enum ReviewedCSVImportIssueKind: String, Hashable {
    case missingRequiredColumn
    case missingWritableColumns
    case duplicateHeader
    case missingEPMCID
    case duplicateEPMCID
    case invalidInclude
    case truncatedRow
    case unknownEPMCID
    case protectedExistingValue
}

struct ReviewedCSVImportIssue: Identifiable, Hashable {
    let id = UUID()
    let severity: ReviewedCSVImportSeverity
    let kind: ReviewedCSVImportIssueKind
    /// CSV 的人类可读行号（表头为第 1 行）；文件级问题为 1。
    let line: Int
    let epmcID: String?
    let message: String
}

/// 一条已经通过 CSV 语法和数据库匹配预检、可以实际写入的变更。
/// nil 表示这个字段本次不触碰，而不是写入 NULL/空字符串。
struct ReviewedCSVRowUpdate: Hashable {
    let line: Int
    let epmcID: String
    let include: String?
    let tags: String?
}

/// 选择 CSV 后生成的不可变预检报告。确认导入时会重新预检一次，避免报告过期。
struct ReviewedCSVImportPlan: Identifiable {
    let id = UUID()
    let csvPath: URL
    let allowOverwrite: Bool
    let headers: [String]
    /// `epmc_id`、`include`、`tags` 中在文件表头缺失的字段；只有缺 epmc_id、
    /// 或 include/tags 两者都缺时会成为阻断性错误。
    let missingExpectedColumns: [String]
    let ignoredColumns: [String]
    let totalRows: Int
    let emptyRows: Int
    let candidateRows: Int
    let unchangedRows: Int
    let unknownRows: Int
    let conflictedRows: Int
    let updates: [ReviewedCSVRowUpdate]
    let issues: [ReviewedCSVImportIssue]

    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    var canApply: Bool { errorCount == 0 }
    var hasChanges: Bool { !updates.isEmpty }
    var plannedIncludeUpdates: Int { updates.reduce(0) { $0 + ($1.include == nil ? 0 : 1) } }
    var plannedTagUpdates: Int { updates.reduce(0) { $0 + ($1.tags == nil ? 0 : 1) } }
}

struct ReviewedCSVImportResult {
    let plan: ReviewedCSVImportPlan
    let updatedRows: Int
    let updatedFields: Int
    let unmatchedAtWrite: Int
    let protectedAtWrite: Int
}

enum ReviewedCSVImportError: Error, LocalizedError {
    case invalidPlan(ReviewedCSVImportPlan)

    var errorDescription: String? {
        switch self {
        case .invalidPlan(let plan):
            return "复筛 CSV 预检发现 \(plan.errorCount) 个错误；请修正后再导入。"
        }
    }
}

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
    /// headerMap 把内部列名映射成人类可读表头（如 q1_ans → 生物医学领域 · 答案）。
    @discardableResult
    static func exportCSV(columns: [String], rows: [[String: DBValue]], to output: URL,
                          excludeColumns: [String], headerMap: [String: String] = [:]) throws -> Int {
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

        var lines: [[String]] = [keep.map { headerMap[$0] ?? $0 }]
        for row in rows {
            lines.append(keep.map { cell(row[$0]) })
        }
        let csv = "\u{FEFF}" + CSV.write(lines)
        try csv.write(to: output, atomically: true, encoding: .utf8)
        return rows.count
    }

    /// 将 None / 空 / "N/A" 标准化为 nil。
    ///
    /// 这是历史通用工具，人工复筛 CSV 不再调用它：复筛中的非空 include 必须严格是
    /// yes/no，`N/A` 也会被报告为非法，而不是悄悄忽略。
    static func normalizeValue(_ v: String?) -> String? {
        guard let v else { return nil }
        let s = v.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.uppercased() == "N/A" { return nil }
        return s
    }

    /// 预检人工复筛 CSV。唯一匹配键固定为 epmc_id；只读取 include/tags，其他列一律忽略。
    ///
    /// - Important: 本方法不写数据库。`allowOverwrite == false` 时，数据库中已有非空的
    ///   include/tags 会被保留，报告中以 warning 标出。
    static func preflightReviewedCSV(_ db: Database, csvPath: URL,
                                     allowOverwrite: Bool = false) throws -> ReviewedCSVImportPlan {
        var text = try String(contentsOf: csvPath, encoding: .utf8)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let parsed = CSV.parse(text)

        guard let rawHeader = parsed.first else {
            let issue = ReviewedCSVImportIssue(
                severity: .error, kind: .missingRequiredColumn, line: 1, epmcID: nil,
                message: "CSV 为空，缺少表头与 epmc_id 列。")
            return ReviewedCSVImportPlan(
                csvPath: csvPath, allowOverwrite: allowOverwrite, headers: [],
                missingExpectedColumns: ["epmc_id", "include", "tags"], ignoredColumns: [],
                totalRows: 0, emptyRows: 0, candidateRows: 0, unchangedRows: 0,
                unknownRows: 0, conflictedRows: 0, updates: [], issues: [issue])
        }

        let expected = ["epmc_id", "include", "tags"]
        let normalizedHeaders = rawHeader.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var positions: [String: Int] = [:]
        var issues: [ReviewedCSVImportIssue] = []
        for (index, name) in normalizedHeaders.enumerated() where !name.isEmpty {
            if positions[name] != nil {
                issues.append(ReviewedCSVImportIssue(
                    severity: .error, kind: .duplicateHeader, line: 1, epmcID: nil,
                    message: "CSV 表头「\(rawHeader[index])」重复；请只保留一列。"))
            } else {
                positions[name] = index
            }
        }

        let missing = expected.filter { positions[$0] == nil }
        if missing.contains("epmc_id") {
            issues.append(ReviewedCSVImportIssue(
                severity: .error, kind: .missingRequiredColumn, line: 1, epmcID: nil,
                message: "CSV 缺少必需列 epmc_id，无法精确匹配文章。"))
        }
        if positions["include"] == nil && positions["tags"] == nil {
            issues.append(ReviewedCSVImportIssue(
                severity: .error, kind: .missingWritableColumns, line: 1, epmcID: nil,
                message: "CSV 至少需要 include 或 tags 其中一列，才有可导入的复筛标注。"))
        }

        let ignoredColumns = rawHeader.enumerated().compactMap { index, value -> String? in
            let normalized = normalizedHeaders[index]
            return !normalized.isEmpty && !expected.contains(normalized) ? value : nil
        }

        func rawCell(_ fields: [String], _ name: String) -> (value: String?, isTruncated: Bool) {
            guard let index = positions[name] else { return (nil, false) }
            guard index < fields.count else { return (nil, true) }
            return (fields[index], false)
        }
        func nonBlank(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func canonicalInclude(_ value: String?) -> String? {
            guard let value = nonBlank(value) else { return nil }
            switch value.lowercased() {
            case "yes": return "yes"
            case "no": return "no"
            default: return nil
            }
        }

        var emptyRows = 0
        var candidateRows = 0
        var unchangedRows = 0
        var seenIDs: [String: Int] = [:]
        struct Candidate {
            let line: Int
            let epmcID: String
            let include: String?
            let tags: String?
        }
        var candidates: [Candidate] = []

        for (rowOffset, fields) in parsed.dropFirst().enumerated() {
            let line = rowOffset + 2
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                emptyRows += 1
                continue
            }

            let idCell = rawCell(fields, "epmc_id")
            let includeCell = rawCell(fields, "include")
            let tagsCell = rawCell(fields, "tags")
            if idCell.isTruncated || includeCell.isTruncated || tagsCell.isTruncated {
                issues.append(ReviewedCSVImportIssue(
                    severity: .warning, kind: .truncatedRow, line: line, epmcID: nil,
                    message: "这一行比表头短，缺失的字段会按空白处理，不会写回数据库。"))
            }

            let requestedInclude = nonBlank(includeCell.value)
            let requestedTags = nonBlank(tagsCell.value)

            // 用户可能在表格软件里保留了额外的阅读列、甚至误插入了一些只含阅读文字的
            // 行。只要 include/tags 都为空，这一行本来就没有可写内容；不应因为缺 ID
            // 把“完全忽略的编辑”升级为阻断整个导入的错误。
            guard let epmcID = nonBlank(idCell.value) else {
                if requestedInclude == nil && requestedTags == nil {
                    unchangedRows += 1
                    continue
                }
                issues.append(ReviewedCSVImportIssue(
                    severity: .error, kind: .missingEPMCID, line: line, epmcID: nil,
                    message: "该行缺少 epmc_id，无法安全匹配文章。"))
                continue
            }
            if requestedInclude != nil && canonicalInclude(includeCell.value) == nil {
                issues.append(ReviewedCSVImportIssue(
                    severity: .error, kind: .invalidInclude, line: line, epmcID: epmcID,
                    message: "include 只能填写 yes 或 no（忽略大小写与首尾空格）；当前值为「\(requestedInclude!)」。"))
                continue
            }
            let include = canonicalInclude(includeCell.value)
            let tags = requestedTags
            guard include != nil || tags != nil else {
                unchangedRows += 1
                continue
            }
            // 只有真正带有手工写入意图的行才参与重复检查。表格中为阅读而保留的
            // 空白重复行不会阻断导入；两行都试图改同一篇文章时才必须由用户消歧。
            if let firstLine = seenIDs[epmcID] {
                issues.append(ReviewedCSVImportIssue(
                    severity: .error, kind: .duplicateEPMCID, line: line, epmcID: epmcID,
                    message: "epmc_id「\(epmcID)」与第 \(firstLine) 行重复；请每篇文章只保留一行。"))
                continue
            }
            seenIDs[epmcID] = line
            candidateRows += 1
            candidates.append(Candidate(line: line, epmcID: epmcID, include: include, tags: tags))
        }

        let current = try db.reviewValues(forEPMCIDs: candidates.map(\.epmcID))
        var updates: [ReviewedCSVRowUpdate] = []
        var unknownRows = 0
        var conflictedRows = 0

        func equivalentInclude(_ imported: String, _ stored: String) -> Bool {
            switch stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes": return imported == "yes"
            case "no": return imported == "no"
            default: return false
            }
        }

        for candidate in candidates {
            guard let existing = current[candidate.epmcID] else {
                unknownRows += 1
                issues.append(ReviewedCSVImportIssue(
                    severity: .warning, kind: .unknownEPMCID, line: candidate.line, epmcID: candidate.epmcID,
                    message: "epmc_id「\(candidate.epmcID)」不在当前项目数据库中，已跳过。"))
                continue
            }

            var includeToWrite: String?
            var tagsToWrite: String?
            var rowConflicted = false

            if let value = candidate.include {
                let stored = nonBlank(existing.include)
                if stored == nil || equivalentInclude(value, stored!) {
                    if stored == nil { includeToWrite = value }
                } else if allowOverwrite {
                    includeToWrite = value
                } else {
                    rowConflicted = true
                    issues.append(ReviewedCSVImportIssue(
                        severity: .warning, kind: .protectedExistingValue, line: candidate.line,
                        epmcID: candidate.epmcID,
                        message: "epmc_id「\(candidate.epmcID)」已有 include 标注，默认不会覆盖。"))
                }
            }

            if let value = candidate.tags {
                let stored = nonBlank(existing.tags)
                if stored == nil || stored == value {
                    if stored == nil { tagsToWrite = value }
                } else if allowOverwrite {
                    tagsToWrite = value
                } else {
                    rowConflicted = true
                    issues.append(ReviewedCSVImportIssue(
                        severity: .warning, kind: .protectedExistingValue, line: candidate.line,
                        epmcID: candidate.epmcID,
                        message: "epmc_id「\(candidate.epmcID)」已有 tags 标注，默认不会覆盖。"))
                }
            }

            if rowConflicted { conflictedRows += 1 }
            if includeToWrite != nil || tagsToWrite != nil {
                updates.append(ReviewedCSVRowUpdate(
                    line: candidate.line, epmcID: candidate.epmcID,
                    include: includeToWrite, tags: tagsToWrite))
            } else if !rowConflicted {
                unchangedRows += 1
            }
        }

        return ReviewedCSVImportPlan(
            csvPath: csvPath, allowOverwrite: allowOverwrite, headers: rawHeader,
            missingExpectedColumns: missing, ignoredColumns: ignoredColumns,
            totalRows: max(0, parsed.count - 1), emptyRows: emptyRows,
            candidateRows: candidateRows, unchangedRows: unchangedRows,
            unknownRows: unknownRows, conflictedRows: conflictedRows,
            updates: updates, issues: issues)
    }

    /// 在确认阶段重新预检后写入。任何 error 都不会写入任何一行。
    static func executeReviewedCSV(_ db: Database, csvPath: URL,
                                   allowOverwrite: Bool = false) throws -> ReviewedCSVImportResult {
        let plan = try preflightReviewedCSV(db, csvPath: csvPath, allowOverwrite: allowOverwrite)
        guard plan.canApply else { throw ReviewedCSVImportError.invalidPlan(plan) }
        guard plan.hasChanges else {
            return ReviewedCSVImportResult(plan: plan, updatedRows: 0, updatedFields: 0,
                                           unmatchedAtWrite: 0, protectedAtWrite: 0)
        }
        let write = try db.applyReviewedCSVUpdates(plan.updates, allowOverwrite: allowOverwrite)
        return ReviewedCSVImportResult(plan: plan, updatedRows: write.updatedRows,
                                       updatedFields: write.updatedFields,
                                       unmatchedAtWrite: write.unmatchedRows,
                                       protectedAtWrite: write.protectedRows)
    }

    /// 兼容旧调用点。新 UI 应先调用 `preflightReviewedCSV` 展示报告，再在用户确认后调用
    /// `executeReviewedCSV`；此封装始终采用“不覆盖已有非空标注”的默认策略。
    static func importReviewedCSV(_ db: Database, csvPath: URL, annotationColumns: [String]) throws
        -> (updated: Int, unmatched: Int, total: Int) {
        _ = annotationColumns  // 人工复筛契约固定只允许 include/tags，拒绝任意动态列写回。
        let result = try executeReviewedCSV(db, csvPath: csvPath, allowOverwrite: false)
        return (result.updatedRows, result.plan.unknownRows + result.unmatchedAtWrite, result.plan.totalRows)
    }
}

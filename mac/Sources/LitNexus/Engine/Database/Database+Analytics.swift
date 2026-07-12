import Foundation

/// 单个分类问题在一篇文献上的 AI 输出。
///
/// 这属于数据库分析层的数据传输对象；界面可按需要显示昵称、理由或导出，
/// 但不需要自己拼动态列名或重新查询文章。
struct PromptAnswerRecord: Identifiable, Equatable {
    var id: String { questionID }
    let questionID: String
    let questionName: String
    let answer: String?
    let reason: String?
}

/// 一篇可用于提示词综合评估的完整文献记录。
///
/// 保留导出所需的基础字段和每个问题的答案/理由。摘要会比较长，因此由展示层
/// 决定是否渲染；分析层始终保留，避免「查看」与「导出」使用两套不一致的筛选。
struct PromptEvaluationRecord: Identifiable, Equatable {
    var id: String { epmcID }
    let epmcID: String
    let pmid: String?
    let doi: String?
    let source: String?
    let pmcid: String?
    let title: String?
    let titleZh: String?
    let abstract: String?
    let abstractZh: String?
    let publicationYear: Int?
    let authors: String?
    let journal: String?
    let firstPublicationDate: String?
    let searchTerm: String?
    let manualInclude: String
    let answers: [PromptAnswerRecord]
}

/// 两种跨问题的人工/AI 对照集合。
///
/// - `humanIncludedButAnyAIDenied`: 人工最终纳入、至少一个启用问题被 AI 判为「否」。
/// - `humanExcludedButAllAIApproved`: 人工最终排除、全部启用问题被 AI 判为「是」。
///
/// 后者就是用户可导出后交给 AI 分析「如何避免这类误放行」的完整集合。
struct PromptCombinedEvaluation: Equatable {
    var humanIncludedButAnyAIDenied: [PromptEvaluationRecord] = []
    var humanExcludedButAllAIApproved: [PromptEvaluationRecord] = []
}

extension Database {
    // ── 统计 ──────────────────────────────────────────────────────────────────

    func stats(questions: [Question]) throws -> [String: Int] {
        var out: [String: Int] = [:]
        out["total"] = try scalarInt("SELECT COUNT(*) FROM articles")
        out["pending_translation"] = try scalarInt(
            "SELECT COUNT(*) FROM articles WHERE title IS NOT NULL AND title != '' AND title_zh IS NULL")
        if Set(try existingColumns()).contains("abstract_zh") {
            out["pending_abstract_translation"] = try scalarInt(
                "SELECT COUNT(*) FROM articles WHERE abstract IS NOT NULL AND abstract != '' AND abstract_zh IS NULL")
        }

        let cols = Set(try existingColumns())
        for q in questions where cols.contains("\(q.id)_ans") {
            let a = "\(q.id)_ans"
            let scope = q.classifyAfterRowID.map { "rowid > \(max(0, $0)) AND " } ?? ""
            out["pending_\(q.id)"] = try scalarInt("SELECT COUNT(*) FROM articles WHERE \(scope)\(a) IS NULL")
            out["\(q.id)_yes"] = try scalarInt("SELECT COUNT(*) FROM articles WHERE \(scope)\(a) = '是'")
            out["\(q.id)_no"] = try scalarInt("SELECT COUNT(*) FROM articles WHERE \(scope)\(a) = '否'")
            out["\(q.id)_other"] = try scalarInt(
                "SELECT COUNT(*) FROM articles WHERE \(scope)\(a) IS NOT NULL AND \(a) NOT IN ('是', '否')")
        }
        if cols.contains("include") {
            out["reviewed_yes"] = try scalarInt("SELECT COUNT(*) FROM articles WHERE include = 'yes'")
            out["reviewed_no"] = try scalarInt("SELECT COUNT(*) FROM articles WHERE include = 'no'")
            out["reviewed_pending"] = try scalarInt("SELECT COUNT(*) FROM articles WHERE include IS NULL")
        }
        return out
    }

    // ── 统计页查询 ────────────────────────────────────────────────────────────

    /// 年代 × 某维度列：返回 [(年份, 维度值, 数量)]，维度值为 nil 表示该列为空。
    func yearDimension(_ column: String, afterRowID: Int? = nil) throws -> [(year: Int, value: String?, count: Int)] {
        guard Identifier.isValid(column), try hasColumn(column) else { return [] }
        let scope = afterRowID.map { " AND rowid > \(max(0, $0))" } ?? ""
        let r = try query("SELECT pub_year AS y, \(column) AS v, COUNT(*) AS c FROM articles WHERE pub_year IS NOT NULL\(scope) GROUP BY y, v ORDER BY y")
        return r.rows.compactMap {
            guard let y = $0["y"]?.intValue else { return nil }
            return (y, $0["v"]?.stringValue, $0["c"]?.intValue ?? 0)
        }
    }

    /// 单列分组计数（含 NULL，NULL 归为 value=nil）。
    func valueCounts(_ column: String, afterRowID: Int? = nil) throws -> [(value: String?, count: Int)] {
        guard Identifier.isValid(column), try hasColumn(column) else { return [] }
        let scope = afterRowID.map { " WHERE rowid > \(max(0, $0))" } ?? ""
        let r = try query("SELECT \(column) AS v, COUNT(*) AS c FROM articles\(scope) GROUP BY v ORDER BY c DESC")
        return r.rows.map { ($0["v"]?.stringValue, $0["c"]?.intValue ?? 0) }
    }

    /// Top N 非空分组（如 Top 期刊）。
    func topValues(_ column: String, limit: Int) throws -> [(value: String, count: Int)] {
        guard Identifier.isValid(column), try hasColumn(column) else { return [] }
        let r = try query("SELECT \(column) AS v, COUNT(*) AS c FROM articles WHERE \(column) IS NOT NULL AND \(column) != '' GROUP BY v ORDER BY c DESC LIMIT \(max(1, limit))")
        return r.rows.compactMap {
            guard let v = $0["v"]?.stringValue else { return nil }
            return (v, $0["c"]?.intValue ?? 0)
        }
    }

    // ── 统计洞察（按期刊/问题聚合）──────────────────────────────────────────────

    /// 每个期刊的总数 / 纳入 / 排除（基于 include 列）。
    ///
    /// 始终返回全部期刊；默认按总文章数降序，便于调用方直接呈现，也允许展示层
    /// 自行按照纳入数或入选率重排。
    func journalStats() throws -> [JournalStat] {
        guard try hasColumn("include") else { return [] }
        let r = try query("""
            SELECT journal_title AS j, COUNT(*) AS total,
                   SUM(CASE WHEN include = 'yes' THEN 1 ELSE 0 END) AS inc,
                   SUM(CASE WHEN include = 'no'  THEN 1 ELSE 0 END) AS exc
            FROM articles
            WHERE journal_title IS NOT NULL AND journal_title != ''
            GROUP BY j
            ORDER BY total DESC, j COLLATE NOCASE ASC
            """)
        return r.rows.compactMap { row in
            guard let j = row["j"]?.stringValue else { return nil }
            return JournalStat(journal: j, total: row["total"]?.intValue ?? 0,
                               included: row["inc"]?.intValue ?? 0, excluded: row["exc"]?.intValue ?? 0)
        }
    }

    /// 某问题已有多少篇有 AI 答案（用于编辑问题文本时判断是否需走知情确认）。
    func answerCount(_ qid: String) throws -> Int {
        guard Identifier.isValid(qid), try hasColumn("\(qid)_ans") else { return 0 }
        return try scalarInt("SELECT COUNT(*) FROM articles WHERE \(qid)_ans IS NOT NULL")
    }

    /// 清空某问题的全部答案与理由（置 NULL），下次分类会重跑。
    func clearClassification(_ qid: String) throws {
        guard Identifier.isValid(qid), try hasColumn("\(qid)_ans") else { return }
        _ = try run("UPDATE articles SET \(qid)_ans = NULL, \(qid)_rea = NULL")
    }

    /// 某问题的 AI 答案 × 人工复筛 混淆计数（仅已复筛且有答案）。
    /// 返回 tp(AI是/纳入) fp(AI是/排除) fn(AI否/纳入) tn(AI否/排除)。
    func questionAgreement(_ qid: String, afterRowID: Int? = nil) throws -> (tp: Int, fp: Int, fn: Int, tn: Int)? {
        guard Identifier.isValid(qid), try hasColumn("\(qid)_ans"), try hasColumn("include") else { return nil }
        let a = "\(qid)_ans"
        let scope = afterRowID.map { " AND rowid > \(max(0, $0))" } ?? ""
        let r = try query("""
            SELECT \(a) AS ans, include AS inc, COUNT(*) AS c
            FROM articles
            WHERE include IS NOT NULL AND \(a) IS NOT NULL\(scope)
            GROUP BY ans, inc
            """)
        var tp = 0, fp = 0, fn = 0, tn = 0
        for row in r.rows {
            let c = row["c"]?.intValue ?? 0
            switch (row["ans"]?.stringValue, row["inc"]?.stringValue) {
            case ("是", "yes"): tp = c
            case ("是", "no"):  fp = c
            case ("否", "yes"): fn = c
            case ("否", "no"):  tn = c
            default: break
            }
        }
        return (tp, fp, fn, tn)
    }

    /// 取 AI 答案与人工裁决分歧的示例（标题 + AI 理由）。
    ///
    /// 不传 `limit` 时返回完整集合；限制数量仅供未来按需加载的调用方使用，
    /// 不能作为统计页默认的数据截断。
    func disagreementExamples(
        _ qid: String,
        aiAnswer: String,
        include: String,
        afterRowID: Int? = nil,
        limit: Int? = nil
    ) throws
        -> [(title: String, reason: String)] {
        guard Identifier.isValid(qid), try hasColumn("\(qid)_ans") else { return [] }
        let limitClause = limit.map { " LIMIT \(max(1, $0))" } ?? ""
        let scope = afterRowID.map { " AND rowid > \(max(0, $0))" } ?? ""
        let r = try query("""
            SELECT title AS t, \(qid)_rea AS r
            FROM articles
            WHERE \(qid)_ans = ? AND include = ? AND title IS NOT NULL AND title != ''\(scope)
            ORDER BY epmc_id COLLATE NOCASE ASC\(limitClause)
            """, [.text(aiAnswer), .text(include)])
        return r.rows.map { ($0["t"]?.stringValue ?? "", $0["r"]?.stringValue ?? "") }
    }

    // ── 跨问题提示词评估 ──────────────────────────────────────────────────────

    /// 读取完整的跨问题人工/AI 对照集合。
    ///
    /// 调用方传入的 questions 决定「全部问题」的范围。桌面端通常传入当前启用的
    /// 分类问题；这样已经退役、仅为保留历史而存在的问题不会悄悄改变当前提示词
    /// 的综合结论。缺失动态列的问题会被安全跳过。
    func promptCombinedEvaluation(questions: [Question]) throws -> PromptCombinedEvaluation {
        let available = try availablePromptQuestions(from: questions)
        guard !available.isEmpty, try hasColumn("include") else { return PromptCombinedEvaluation() }

        let applicable = available.map { scopeClause(for: $0, alias: "a") }
        let anyDenied = zip(available, applicable).map { question, scope in
            "(\(scope) AND a.\(question.id)_ans = '否')"
        }.joined(separator: " OR ")
        // 对于在问题创建前已入库的文章，“仅未来”的问题不适用，因此不能要求它也
        // 回答“是”。所有实际适用的问题都判是，才属于共同推荐。
        let allApproved = zip(available, applicable).map { question, scope in
            "((NOT (\(scope))) OR a.\(question.id)_ans = '是')"
        }.joined(separator: " AND ")
        let anyApplicable = applicable.map { "(\($0))" }.joined(separator: " OR ")

        return PromptCombinedEvaluation(
            humanIncludedButAnyAIDenied: try promptEvaluationRecords(
                where: "a.include = 'yes' AND (\(anyDenied))", questions: available),
            humanExcludedButAllAIApproved: try promptEvaluationRecords(
                where: "a.include = 'no' AND (\(anyApplicable)) AND (\(allApproved))", questions: available)
        )
    }

    /// 导出「全部启用问题均判是、但人工最终排除」的完整记录。
    ///
    /// 输出固定包含识别、出处、正文、人工结论，以及每个问题的答案/理由；不受普通
    /// CSV 导出列开关影响，因为它的用途就是把这些反例交给 AI/人工改进提示词。
    /// 若集合为空，返回 0 且不生成空文件。
    @discardableResult
    func exportHumanExcludedButAllAIApproved(questions: [Question], to output: URL) throws -> Int {
        let available = try availablePromptQuestions(from: questions)
        guard !available.isEmpty else {
            throw DBError.exportFilter("没有可用于综合评估的分类问题。")
        }
        guard try hasColumn("include") else {
            throw DBError.exportFilter("当前数据库没有人工复筛列 include，无法导出对照记录。")
        }

        let applicable = available.map { scopeClause(for: $0, alias: "a") }
        let allApproved = zip(available, applicable).map { question, scope in
            "((NOT (\(scope))) OR a.\(question.id)_ans = '是')"
        }.joined(separator: " AND ")
        let anyApplicable = applicable.map { "(\($0))" }.joined(separator: " OR ")
        let records = try promptEvaluationRecords(
            where: "a.include = 'no' AND (\(anyApplicable)) AND (\(allApproved))", questions: available)
        guard !records.isEmpty else { return 0 }

        var header = [
            "EPMC ID", "PMID", "DOI", "来源", "PMCID",
            "标题（原文）", "标题（译文）", "摘要（原文）", "摘要（译文）",
            "年份", "作者", "期刊", "首发日期", "命中检索式", "人工复筛结果",
        ]
        for question in available {
            header.append("\(question.displayName) · AI 答案")
            header.append("\(question.displayName) · AI 理由")
        }

        var rows: [[String]] = [header]
        rows.reserveCapacity(records.count + 1)
        for record in records {
            var row: [String] = []
            row.append(record.epmcID)
            row.append(record.pmid ?? "")
            row.append(record.doi ?? "")
            row.append(record.source ?? "")
            row.append(record.pmcid ?? "")
            row.append(record.title ?? "")
            row.append(record.titleZh ?? "")
            row.append(record.abstract ?? "")
            row.append(record.abstractZh ?? "")
            row.append(record.publicationYear.map(String.init) ?? "")
            row.append(record.authors ?? "")
            row.append(record.journal ?? "")
            row.append(record.firstPublicationDate ?? "")
            row.append(record.searchTerm ?? "")
            row.append(record.manualInclude)
            for answer in record.answers {
                row.append(answer.answer ?? "")
                row.append(answer.reason ?? "")
            }
            rows.append(row)
        }

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let csv = "\u{FEFF}" + CSV.write(rows)
        try csv.write(to: output, atomically: true, encoding: .utf8)
        return records.count
    }

    // MARK: Internal prompt-evaluation query helpers

    private func availablePromptQuestions(from questions: [Question]) throws -> [Question] {
        let columns = Set(try existingColumns())
        return questions.filter { question in
            Identifier.isValid(question.id) && columns.contains("\(question.id)_ans")
        }
    }

    private func scopeClause(for question: Question, alias: String) -> String {
        guard let after = question.classifyAfterRowID else { return "1=1" }
        return "\(alias).rowid > \(max(0, after))"
    }

    private func promptEvaluationRecords(where whereClause: String, questions: [Question]) throws
        -> [PromptEvaluationRecord] {
        guard !questions.isEmpty else { return [] }
        let columns = Set(try existingColumns())
        let baseSelections = [
            "a.epmc_id AS epmc_id", "a.pmid AS pmid", "a.doi AS doi", "a.source AS source", "a.pmcid AS pmcid",
            "a.title AS title", "a.title_zh AS title_zh", "a.abstract AS abstract", "a.abstract_zh AS abstract_zh",
            "a.pub_year AS pub_year", "a.author_string AS author_string", "a.journal_title AS journal_title",
            "a.first_publication_date AS first_publication_date", "a.query_search_term AS query_search_term",
            "a.include AS manual_include",
        ]
        var selections = baseSelections
        for (index, question) in questions.enumerated() {
            let ans = "\(question.id)_ans"
            let rea = "\(question.id)_rea"
            selections.append("a.\(ans) AS prompt_\(index)_ans")
            if columns.contains(rea) {
                selections.append("a.\(rea) AS prompt_\(index)_rea")
            } else {
                selections.append("NULL AS prompt_\(index)_rea")
            }
        }

        let result = try query("""
            SELECT \(selections.joined(separator: ", "))
            FROM articles AS a
            WHERE \(whereClause)
            ORDER BY a.pub_year DESC, a.epmc_id COLLATE NOCASE ASC
            """)

        return result.rows.compactMap { row in
            guard let epmcID = row["epmc_id"]?.stringValue, !epmcID.isEmpty else { return nil }
            let answers = questions.enumerated().map { index, question in
                PromptAnswerRecord(
                    questionID: question.id,
                    questionName: question.displayName,
                    answer: row["prompt_\(index)_ans"]?.stringValue,
                    reason: row["prompt_\(index)_rea"]?.stringValue
                )
            }
            return PromptEvaluationRecord(
                epmcID: epmcID,
                pmid: row["pmid"]?.stringValue,
                doi: row["doi"]?.stringValue,
                source: row["source"]?.stringValue,
                pmcid: row["pmcid"]?.stringValue,
                title: row["title"]?.stringValue,
                titleZh: row["title_zh"]?.stringValue,
                abstract: row["abstract"]?.stringValue,
                abstractZh: row["abstract_zh"]?.stringValue,
                publicationYear: row["pub_year"]?.intValue,
                authors: row["author_string"]?.stringValue,
                journal: row["journal_title"]?.stringValue,
                firstPublicationDate: row["first_publication_date"]?.stringValue,
                searchTerm: row["query_search_term"]?.stringValue,
                manualInclude: row["manual_include"]?.stringValue ?? "",
                answers: answers
            )
        }
    }
}

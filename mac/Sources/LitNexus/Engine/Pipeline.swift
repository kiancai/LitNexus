import Foundation

// 流水线步骤的纯逻辑 + 供界面调用的高层封装。对应 Python 参考的 pipeline.py 与 GUI 的 _do_*。

struct MergeResult {
    var inserted: Int
    var skipped: Int
    var errors: Int
    var files: Int
}

enum Pipeline {
    /// 合并 downloadsDir 下「尚未合并」的 *.jsonl 入库（去重）；合并后移入 _merged/，
    /// 保证每个下载文件只处理一次，重复点击不会反复导入。
    static func mergeJSONL(db: Database, downloadsDir: URL, reporter: ProgressReporter?) throws -> MergeResult {
        // 只看顶层 *.jsonl（_merged 是子目录，自然被排除）
        let files = ((try? FileManager.default.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let mergedDir = downloadsDir.appendingPathComponent("_merged")
        var inserted = 0, skipped = 0, errors = 0
        let taskID = reporter?.addTask("合并入库", total: files.count)
        for f in files {
            if reporter?.isCancelled() == true { throw PipelineCancelled() }
            reporter?.log("处理：\(f.lastPathComponent)")
            var batch: [[String: DBValue]] = []
            var fileErrors = 0
            for raw in ArticleIO.iterJSONL(f) {
                let parsed = ArticleIO.parseArticle(raw)
                if case .text = parsed["epmc_id"] { batch.append(parsed) } else { fileErrors += 1 }
            }
            let (i, s) = try db.insertArticles(batch)
            // 累积检索渠道：本文件里每篇的 (epmc_id, query_search_term, kind)。kind 由文件名判断。
            let kind = termKind(for: f.lastPathComponent)
            try? db.insertArticleTerms(termPairs(batch, kind: kind))
            inserted += i; skipped += s; errors += fileErrors
            reporter?.log("  \(f.lastPathComponent): 插入 \(i)，重复 \(s)，错误 \(fileErrors)")
            // 已合并的文件移入 _merged/，避免下次重复导入
            try? FileManager.default.createDirectory(at: mergedDir, withIntermediateDirectories: true)
            let dest = mergedDir.appendingPathComponent(f.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: f, to: dest)
            if let taskID { reporter?.update(taskID, advance: 1) }
        }
        if let taskID { reporter?.complete(taskID) }
        return MergeResult(inserted: inserted, skipped: skipped, errors: errors, files: files.count)
    }

    /// 从文件名判断检索渠道类型。
    static func termKind(for filename: String) -> String {
        if filename.hasPrefix("epmc_keywords") { return "keyword" }
        if filename.hasPrefix("epmc_journals") { return "journal" }
        return "unknown"
    }

    /// 从一批解析后的文章里抽出 (epmc_id, query_search_term, kind) 命中对。
    static func termPairs(_ batch: [[String: DBValue]], kind: String)
        -> [(epmcID: String, term: String, kind: String)] {
        batch.compactMap { art in
            guard let id = art["epmc_id"]?.stringValue,
                  let term = art["query_search_term"]?.stringValue, !term.isEmpty else { return nil }
            return (id, term, kind)
        }
    }

    /// 重建检索渠道表：扫描 _merged/*.jsonl 重灌 article_terms（免费补全历史，无需重新下载）。
    /// 返回处理的文件数与累计命中对数。
    @discardableResult
    static func rebuildArticleTerms(db: Database, downloadsDir: URL, reporter: ProgressReporter?) throws
        -> (files: Int, pairs: Int) {
        let mergedDir = downloadsDir.appendingPathComponent("_merged")
        let files = ((try? FileManager.default.contentsOfDirectory(at: mergedDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try db.clearArticleTerms()
        let taskID = reporter?.addTask("重建检索渠道", total: files.count)
        var totalPairs = 0
        for f in files {
            if reporter?.isCancelled() == true { throw PipelineCancelled() }
            let kind = termKind(for: f.lastPathComponent)
            let batch: [[String: DBValue]] = ArticleIO.iterJSONL(f).map { ArticleIO.parseArticle($0) }
            let pairs = termPairs(batch, kind: kind)
            try db.insertArticleTerms(pairs)
            totalPairs += pairs.count
            reporter?.log("  \(f.lastPathComponent)：\(pairs.count) 条命中")
            if let taskID { reporter?.update(taskID, advance: 1) }
        }
        if let taskID { reporter?.complete(taskID) }
        return (files.count, totalPairs)
    }

    /// 按 filterMode 导出到 CSV，返回行数（0 表示结果为空）。
    /// 问题列：导出开=用昵称作表头；导出关=整列排除。
    @discardableResult
    static func exportArticles(db: Database, config cfg: AppConfig, filterMode: String, output: URL) throws -> Int {
        let (columns, rows) = try db.fetchForExport(filterMode: filterMode)
        if rows.isEmpty { return 0 }
        var exclude = Set(cfg.export.excludeColumns)
        var headerMap: [String: String] = [:]
        for q in cfg.classify.questions {
            let ans = "\(q.id)_ans", rea = "\(q.id)_rea"
            if q.export {
                headerMap[ans] = "\(q.displayName) · 答案"
                headerMap[rea] = "\(q.displayName) · 理由"
            } else {
                exclude.insert(ans); exclude.insert(rea)
            }
        }
        return try ArticleIO.exportCSV(columns: columns, rows: rows, to: output,
                                       excludeColumns: Array(exclude), headerMap: headerMap)
    }

    // ── 高层封装（界面按钮直接调用，返回一句结果摘要）────────────────────────

    static func doDownload(config cfg: AppConfig, workspace ws: Workspace, mode: String, days: Int,
                           reporter: ProgressReporter?) throws -> String {
        let r = try EPMCClient.runDownload(config: cfg, workspace: ws, mode: mode, days: days, reporter: reporter)
        let sum = r.journalCount + r.keywordCount
        if sum == 0 { return "未取到新文献" }
        var parts: [String] = []
        if r.journalCount > 0 { parts.append("期刊 \(r.journalCount) 篇") }
        if r.keywordCount > 0 { parts.append("关键词 \(r.keywordCount) 篇") }
        // 只有单一来源时不重复显示总数
        return parts.count > 1 ? parts.joined(separator: " · ") + "，共 \(sum) 篇" : parts.joined()
    }

    static func doMerge(config cfg: AppConfig, workspace ws: Workspace, reporter: ProgressReporter?) throws -> String {
        let db = try Database(path: ws.dbPath, config: cfg)
        let r = try mergeJSONL(db: db, downloadsDir: ws.downloadsDir, reporter: reporter)
        if r.files == 0 { return "没有新的下载文件可合并" }
        var s = "新增入库 \(r.inserted) 篇"
        if r.skipped > 0 { s += " · 去重 \(r.skipped)" }
        if r.errors > 0 { s += " · 错误 \(r.errors)" }
        return s
    }

    static func doTranslate(config cfg: AppConfig, workspace ws: Workspace, reporter: ProgressReporter?) throws -> String {
        let db = try Database(path: ws.dbPath, config: cfg)
        let (t, f) = try AIClient.runTranslation(db: db, config: cfg.translate, ai: cfg.resolvedAI, reporter: reporter)
        if t == 0 && f == 0 { return "没有需要翻译的内容" }
        var s = "翻译 \(t) 篇"
        if f > 0 { s += " · 失败 \(f)" }
        return s
    }

    static func doClassify(config cfg: AppConfig, workspace ws: Workspace, reporter: ProgressReporter?) throws -> String {
        let db = try Database(path: ws.dbPath, config: cfg)
        let (p, f) = try AIClient.runClassification(db: db, config: cfg.classify, ai: cfg.resolvedAI, reporter: reporter)
        if p == 0 && f == 0 { return "没有需要分类的文章" }
        var s = "分类 \(p) 篇"
        if f > 0 { s += " · 失败 \(f)" }
        return s
    }

    static func doExport(config cfg: AppConfig, workspace ws: Workspace, filterMode: String,
                         reporter: ProgressReporter?) throws -> String {
        let db = try Database(path: ws.dbPath, config: cfg)
        let out = ws.exportsDir.appendingPathComponent("articles_\(EPMCClient.timestamp()).csv")
        let n = try exportArticles(db: db, config: cfg, filterMode: filterMode, output: out)
        return n == 0 ? "查询结果为空，未生成 CSV" : "已导出 \(n) 篇 → \(out.lastPathComponent)"
    }
}

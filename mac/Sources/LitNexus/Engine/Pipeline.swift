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
            reporter?.log("处理：\(f.lastPathComponent)")
            var batch: [[String: DBValue]] = []
            var fileErrors = 0
            for raw in ArticleIO.iterJSONL(f) {
                let parsed = ArticleIO.parseArticle(raw)
                if case .text = parsed["epmc_id"] { batch.append(parsed) } else { fileErrors += 1 }
            }
            let (i, s) = try db.insertArticles(batch)
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

    /// 按 filterMode 导出到 CSV，返回行数（0 表示结果为空）。
    @discardableResult
    static func exportArticles(db: Database, config cfg: AppConfig, filterMode: String, output: URL) throws -> Int {
        let (columns, rows) = try db.fetchForExport(filterMode: filterMode)
        if rows.isEmpty { return 0 }
        return try ArticleIO.exportCSV(columns: columns, rows: rows, to: output, excludeColumns: cfg.export.excludeColumns)
    }

    // ── 高层封装（界面按钮直接调用，返回一句结果摘要）────────────────────────

    static func doDownload(config cfg: AppConfig, workspace ws: Workspace, mode: String, days: Int,
                           reporter: ProgressReporter?) throws -> String {
        let files = try EPMCClient.runDownload(config: cfg, workspace: ws, mode: mode, days: days, reporter: reporter)
        return "生成 \(files.count) 个 JSONL 文件"
    }

    static func doMerge(config cfg: AppConfig, workspace ws: Workspace, reporter: ProgressReporter?) throws -> String {
        let db = try Database(path: ws.dbPath, config: cfg)
        let r = try mergeJSONL(db: db, downloadsDir: ws.downloadsDir, reporter: reporter)
        if r.files == 0 { return "没有新的下载文件可合并" }
        return "处理 \(r.files) 个文件：新增 \(r.inserted)，重复 \(r.skipped)，错误 \(r.errors)"
    }

    static func doTranslate(config cfg: AppConfig, workspace ws: Workspace, reporter: ProgressReporter?) throws -> String {
        let db = try Database(path: ws.dbPath, config: cfg)
        let (t, f) = try AIClient.runTranslation(db: db, config: cfg.translate, ai: cfg.resolvedAI, reporter: reporter)
        return "翻译 \(t)，失败 \(f)"
    }

    static func doClassify(config cfg: AppConfig, workspace ws: Workspace, reporter: ProgressReporter?) throws -> String {
        let db = try Database(path: ws.dbPath, config: cfg)
        let (p, f) = try AIClient.runClassification(db: db, config: cfg.classify, ai: cfg.resolvedAI, reporter: reporter)
        return "分类 \(p)，失败 \(f)"
    }

    static func doExport(config cfg: AppConfig, workspace ws: Workspace, filterMode: String,
                         reporter: ProgressReporter?) throws -> String {
        let db = try Database(path: ws.dbPath, config: cfg)
        let out = ws.exportsDir.appendingPathComponent("articles_\(EPMCClient.timestamp()).csv")
        let n = try exportArticles(db: db, config: cfg, filterMode: filterMode, output: out)
        return n == 0 ? "查询结果为空，未生成 CSV" : "已导出 \(n) 篇 → \(out.lastPathComponent)"
    }
}

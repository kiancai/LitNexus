import Foundation

extension AppState {
    // ── CSV 导出 / 导入 ────────────────────────────────────────────────────────

    /// 可选导出列（文献本体 + 人工标注列；问题列由各问题的「导出」开关单独控制，不在此处）。
    func exportableColumns() -> [(col: String, label: String)] {
        let labels: [String: String] = [
            "epmc_id": "EPMC ID", "pmid": "PMID", "doi": "DOI", "source": "来源(MED/PPR)",
            "pmcid": "PMCID", "title": "标题(原文)", "abstract": "摘要(原文)", "pub_year": "年份",
            "author_string": "作者", "journal_title": "期刊", "first_publication_date": "首发日期",
            "query_search_term": "命中检索式", "journal_info_json": "期刊信息(JSON)",
            "keyword_list_json": "关键词(JSON)", "title_zh": "标题(译文)", "abstract_zh": "摘要(译文)",
        ]
        var out = Database.baseColumns.map { (col: $0, label: labels[$0] ?? $0) }
        for c in config.schema.customColumns {
            let l = c == "include" ? "复筛纳入(include)" : c == "tags" ? "标签(tags)" : c
            out.append((col: c, label: l))
        }
        return out
    }

    /// 切换某列是否导出（写入 export.excludeColumns 并持久化）。
    func setColumnExported(_ col: String, _ exported: Bool) {
        // 复筛 CSV 的机器合同：这三列永远不能被导出设置排除。
        // `include` / `tags` 可为空，但表头必须存在，才能让用户知道该填写哪里。
        let requiredForReview = Set(["epmc_id", "include", "tags"])
        if requiredForReview.contains(col), !exported { return }
        var ex = Set(config.export.excludeColumns)
        if exported { ex.remove(col) } else { ex.insert(col) }
        ex.subtract(requiredForReview)
        config.export.excludeColumns = Array(ex)
        persistConfig()
    }

    /// 数据页是导出范围唯一的交互入口。每次点选范围都立即写入项目配置，下一次
    /// 打开数据页会沿用该选择，不再通过配置页维护一份重复的“默认值”。
    func setExportFilter(_ filter: String) {
        let allowed: Set<String> = ["all", "pending", "included", "excluded"]
        let normalized = allowed.contains(filter) ? filter : "pending"
        guard config.export.filter != normalized else { return }
        config.export.filter = normalized
        persistConfig()
    }

    func export(filter: String) {
        guard let ws = workspace else { return }
        let cfg = config
        DispatchQueue.global().async {
            let msg: String
            do { msg = try Pipeline.doExport(config: cfg, workspace: ws, filterMode: filter, reporter: nil) }
            catch { msg = "导出失败：\(error.localizedDescription)" }
            DispatchQueue.main.async { self.toast = msg; self.refreshStats() }
        }
    }

    /// 第一步：只预检人工复筛 CSV，不写入数据库。UI 应展示返回的报告，并让用户显式
    /// 确认后再调用 `confirmReviewCSVImport`。
    func prepareReviewCSVImport(_ url: URL, allowOverwrite: Bool = false,
                                completion: @escaping (Result<ReviewedCSVImportPlan, Error>) -> Void) {
        guard let ws = workspace else {
            completion(.failure(DBError.exportFilter("当前没有打开项目，无法预检复筛 CSV。")))
            return
        }
        let cfg = config
        DispatchQueue.global().async {
            do {
                let db = try Database(path: ws.dbPath, config: cfg)
                let plan = try ArticleIO.preflightReviewedCSV(db, csvPath: url, allowOverwrite: allowOverwrite)
                DispatchQueue.main.async { completion(.success(plan)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// 第二步：用户确认预检报告后才写入。写前会重新预检，并只在确有可写变更时备份。
    func confirmReviewCSVImport(_ url: URL, allowOverwrite: Bool = false,
                                completion: ((Result<ReviewedCSVImportResult, Error>) -> Void)? = nil) {
        guard let ws = workspace else {
            let error = DBError.exportFilter("当前没有打开项目，无法导入复筛 CSV。")
            toast = "导入失败：\(error.localizedDescription)"
            completion?(.failure(error))
            return
        }
        let cfg = config
        DispatchQueue.global().async {
            do {
                let db = try Database(path: ws.dbPath, config: cfg)
                let plan = try ArticleIO.preflightReviewedCSV(db, csvPath: url, allowOverwrite: allowOverwrite)
                guard plan.canApply else { throw ReviewedCSVImportError.invalidPlan(plan) }
                let backupName: String?
                if plan.hasChanges {
                    backupName = try db.backup().lastPathComponent
                } else {
                    backupName = nil
                }
                let result = try ArticleIO.executeReviewedCSV(db, csvPath: url, allowOverwrite: allowOverwrite)
                DispatchQueue.main.async {
                    let backup = backupName.map { " · 已备份 \($0)" } ?? ""
                    self.toast = "导入完成：更新 \(result.updatedRows) 行 / \(result.updatedFields) 项，未匹配 \(result.plan.unknownRows + result.unmatchedAtWrite) 行\(backup)"
                    self.refreshStats()
                    completion?(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    self.toast = "导入失败：\(error.localizedDescription)"
                    completion?(.failure(error))
                }
            }
        }
    }

    /// 兼容旧按钮入口：现在只做预检，绝不因选择文件而直接写库。新 DataView 会使用上面
    /// 的两步 API 展示报告与确认界面。
    func importCSV(_ url: URL) {
        prepareReviewCSVImport(url) { result in
            switch result {
            case .success(let plan):
                if plan.canApply {
                    self.toast = "已完成复筛 CSV 预检：可更新 \(plan.updates.count) 行。请确认后导入。"
                } else {
                    self.toast = "复筛 CSV 预检发现 \(plan.errorCount) 个错误，未写入数据库。"
                }
            case .failure(let error):
                self.toast = "读取 CSV 失败：\(error.localizedDescription)"
            }
        }
    }

    // ── 数据库整体导出 / 导入 / 清空 ─────────────────────────────────────────────

    /// 导出整库为一份独立 .db（新格式、已 VACUUM）。
    func exportDatabase(to dest: URL) {
        guard let ws = workspace else { return }
        let cfg = config
        DispatchQueue.global().async {
            let msg: String
            do {
                let db = try Database(path: ws.dbPath, config: cfg)
                try db.exportTo(dest)
                msg = "已导出数据库 → \(dest.lastPathComponent)"
            } catch { msg = "导出数据库失败：\(error.localizedDescription)" }
            DispatchQueue.main.async { self.toast = msg }
        }
    }

    /// 第一步：检查源库的问题列。无问题列则直接导入；有则弹出人工对齐界面。
    func beginImport(from source: URL, strategy: Database.ImportStrategy) {
        guard let ws = workspace else { return }
        let cfg = config
        DispatchQueue.global().async {
            do {
                let db = try Database(path: ws.dbPath, config: cfg)
                let insp = try db.inspectImport(source)
                if insp.sourceQuestions.isEmpty {
                    DispatchQueue.main.async { self.executeImport(from: source, strategy: strategy, questionPairs: []) }
                    return
                }
                let destQs = cfg.classify.questions
                let rows = insp.sourceQuestions.map { sq -> ImportQRow in
                    var action: QMapAction = .skip   // 默认不导入，避免误合并
                    if let t = sq.text, let m = destQs.first(where: { $0.text == t }) { action = .map(m.id) }
                    return ImportQRow(srcId: sq.id, srcNickname: sq.nickname, srcText: sq.text, action: action)
                }
                let plan = ImportPlan(source: source, strategy: strategy, total: insp.total, rows: rows)
                DispatchQueue.main.async { self.importPlan = plan }
            } catch {
                DispatchQueue.main.async { self.toast = "读取源库失败：\(error.localizedDescription)" }
            }
        }
    }

    /// 第二步：用户确认映射后，按映射建列并导入。
    func confirmImport(_ plan: ImportPlan) {
        importPlan = nil
        var pairs: [(dest: String, src: String)] = []
        for row in plan.rows {
            switch row.action {
            case .skip: continue
            case .map(let destId):
                pairs.append((dest: "\(destId)_ans", src: "\(row.srcId)_ans"))
                pairs.append((dest: "\(destId)_rea", src: "\(row.srcId)_rea"))
            case .createNew:
                let id = config.classify.allocateQuestionID()
                config.classify.questions.append(Question(
                    id: id, nickname: row.srcNickname ?? "", text: row.srcText ?? "", classify: true, export: true))
                pairs.append((dest: "\(id)_ans", src: "\(row.srcId)_ans"))
                pairs.append((dest: "\(id)_rea", src: "\(row.srcId)_rea"))
            }
        }
        persistConfig()
        if let ws = workspace { _ = try? Database(path: ws.dbPath, config: config) }  // 补齐新列与元数据
        executeImport(from: plan.source, strategy: plan.strategy, questionPairs: pairs)
    }

    /// 实际执行导入（导入前自动备份为 .db.bak）。
    private func executeImport(from source: URL, strategy: Database.ImportStrategy,
                              questionPairs: [(dest: String, src: String)]) {
        guard let ws = workspace else { return }
        let cfg = config
        DispatchQueue.global().async {
            let msg: String
            do {
                let db = try Database(path: ws.dbPath, config: cfg)
                let bak = try db.backup()
                let (ins, skip, total) = try db.importFromDatabase(source, strategy: strategy, questionColumnPairs: questionPairs)
                let how = strategy == .fillEmpty ? "补齐空缺" : "跳过已有"
                msg = "导入完成（\(how)）：新增 \(ins)，既有 \(skip)，源库 \(total) 篇 · 已备份 \(bak.lastPathComponent)"
            } catch { msg = "导入数据库失败：\(error.localizedDescription)" }
            DispatchQueue.main.async { self.toast = msg; self.refreshStats() }
        }
    }

    /// 清空当前项目数据库（删除全部文章，保留结构）。清空前自动备份。
    func clearDatabase() {
        guard let ws = workspace else { return }
        let cfg = config
        DispatchQueue.global().async {
            let msg: String
            do {
                let db = try Database(path: ws.dbPath, config: cfg)
                let bak = try db.backup()  // 清空前快照，可回滚
                try db.clearArticles()
                msg = "已清空全部文章 · 已备份 \(bak.lastPathComponent)"
            } catch { msg = "清空失败：\(error.localizedDescription)" }
            DispatchQueue.main.async { self.toast = msg; self.refreshStats() }
        }
    }
}

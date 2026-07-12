import Foundation

// Statistics are deliberately split into a small, always-visible base and
// lazy insights.  The former makes entering the statistics page predictable;
// the latter only runs when a user opens the card that needs it.

extension AppState {
    // ── Cache lifecycle ──────────────────────────────────────────────────────

    /// Discard the in-memory statistics snapshot after any project-data or
    /// statistics-relevant configuration write. The cache never reaches disk.
    ///
    /// All callers are UI actions and therefore arrive on the main thread. A
    /// generation token makes any already-running SQLite read harmless: its
    /// result is simply ignored instead of overwriting newer project data.
    func invalidateStatsCache() {
        statsCacheGeneration &+= 1
        statsBundleCache = nil
        statsCacheWorkspacePath = nil
        statsBasicLoading = false
        statsInsightLoading = false

        let basicCompletions = statsBasicCompletions
        let insightRequests = statsInsightRequests
        statsBasicCompletions = []
        statsInsightRequests = []
        basicCompletions.forEach { $0(nil) }
        insightRequests.forEach { $0.completion(nil) }
    }

    /// Load the lightweight, always-visible statistics. Repeated calls for the
    /// active project reuse one in-memory `StatsBundle` and join an in-flight
    /// request rather than issuing duplicate SQLite aggregations.
    func computeStats(_ completion: @escaping (StatsBundle?) -> Void) {
        guard let ws = workspace, FileManager.default.fileExists(atPath: ws.dbPath.path) else {
            completion(nil)
            return
        }
        let key = ws.root.standardizedFileURL.path
        if let cache = statsBundleCache, statsCacheWorkspacePath == key {
            completion(cache)
            return
        }

        statsBasicCompletions.append(completion)
        guard !statsBasicLoading else { return }
        statsBasicLoading = true

        let cfg = config
        let generation = statsCacheGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let basic = Self.makeBasicStatsBundle(workspace: ws, config: cfg)
            DispatchQueue.main.async {
                guard self.statsCacheGeneration == generation,
                      self.workspace?.root.standardizedFileURL.path == key else {
                    return
                }
                self.statsBasicLoading = false
                self.statsBundleCache = basic
                self.statsCacheWorkspacePath = key
                self.stats = basic?.overview ?? [:]
                let callbacks = self.statsBasicCompletions
                self.statsBasicCompletions = []
                callbacks.forEach { $0(basic) }
            }
        }
    }

    /// Load one or more expensive insight groups on demand. The returned bundle
    /// is still the same snapshot as `computeStats`, now enriched with the
    /// requested data and its `loadedInsights` marker.
    func loadStatsInsights(_ insights: Set<StatsInsight>, completion: @escaping (StatsBundle?) -> Void) {
        guard !insights.isEmpty else {
            computeStats(completion)
            return
        }
        computeStats { [weak self] basic in
            guard let self, basic != nil else { completion(nil); return }
            self.enqueueStatsInsightRequest(insights, completion: completion)
        }
    }

    private func enqueueStatsInsightRequest(
        _ insights: Set<StatsInsight>,
        completion: @escaping (StatsBundle?) -> Void
    ) {
        guard let cache = statsBundleCache else { completion(nil); return }
        if insights.isSubset(of: cache.loadedInsights) {
            completion(cache)
            return
        }
        statsInsightRequests.append(StatsInsightRequest(insights: insights, completion: completion))
        startNextStatsInsightBatchIfNeeded()
    }

    private func startNextStatsInsightBatchIfNeeded() {
        guard !statsInsightLoading, let cache = statsBundleCache,
              let ws = workspace else { return }

        let requested = statsInsightRequests.reduce(into: Set<StatsInsight>()) { partial, request in
            partial.formUnion(request.insights)
        }
        let missing = requested.subtracting(cache.loadedInsights)
        if missing.isEmpty {
            resolveLoadedInsightRequests(with: cache)
            return
        }

        statsInsightLoading = true
        let cfg = config
        let journals = cache.journals
        let key = ws.root.standardizedFileURL.path
        let generation = statsCacheGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let additions = Self.makeStatsInsights(
                workspace: ws, config: cfg, journals: journals, insights: missing)
            DispatchQueue.main.async {
                guard self.statsCacheGeneration == generation,
                      self.workspace?.root.standardizedFileURL.path == key else {
                    return
                }
                self.statsInsightLoading = false
                guard let additions, var merged = self.statsBundleCache else {
                    // A transient read failure must not strand callers. Do not
                    // mark the insight loaded, so a later explicit retry works.
                    let requests = self.statsInsightRequests
                    self.statsInsightRequests = []
                    requests.forEach { $0.completion(self.statsBundleCache) }
                    return
                }
                merged.apply(insights: additions)
                self.statsBundleCache = merged
                self.resolveLoadedInsightRequests(with: merged)
                self.startNextStatsInsightBatchIfNeeded()
            }
        }
    }

    private func resolveLoadedInsightRequests(with cache: StatsBundle) {
        var stillWaiting: [StatsInsightRequest] = []
        for request in statsInsightRequests {
            if request.insights.isSubset(of: cache.loadedInsights) {
                request.completion(cache)
            } else {
                stillWaiting.append(request)
            }
        }
        statsInsightRequests = stillWaiting
    }

    // ── Public actions ───────────────────────────────────────────────────────

    /// 重建检索渠道（扫 _merged/*.jsonl 重灌 article_terms）。这会令关键词洞察
    /// 失效，因此完成后让下一次读取重新建立轻量快照。
    func rebuildChannelMap(_ completion: @escaping () -> Void = {}) {
        guard let ws = workspace, !rebuildingChannels else { return }
        let cfg = config
        rebuildingChannels = true
        DispatchQueue.global().async {
            var msg = "检索渠道已重建"
            if let db = try? Database(path: ws.dbPath, config: cfg) {
                if let r = try? Pipeline.rebuildArticleTerms(db: db, downloadsDir: ws.downloadsDir, reporter: nil) {
                    msg = "检索渠道已重建：\(r.files) 个文件、\(r.pairs) 条命中"
                } else { msg = "重建失败" }
            } else { msg = "重建失败：无法打开数据库" }
            DispatchQueue.main.async {
                self.rebuildingChannels = false
                self.invalidateStatsCache()
                self.toast = msg
                completion()
            }
        }
    }

    /// 导出「全部当前启用问题均判是、但人工最终排除」的完整 CSV。
    ///
    /// 此导出不会修改项目数据，也不会改变统计缓存；文件写入当前项目的 exports/
    /// 目录，供用户交给 AI 归纳需要补充的排除性提示词。
    func exportAllQuestionsApprovedButExcluded() {
        guard let ws = workspace else { return }
        let cfg = config
        // 综合对照的“全部问题”是当前仍启用 AI 分类的问题；归档问题仅保留
        // 历史证据，不能继续改变当前提示词的判断边界。
        let questions = cfg.classify.questions.filter(\.isActiveForClassification)
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do {
                let db = try Database(path: ws.dbPath, config: cfg)
                let output = ws.exportsDir.appendingPathComponent(
                    "all_ai_yes_human_excluded_\(EPMCClient.timestamp()).csv")
                let count = try db.exportHumanExcludedButAllAIApproved(questions: questions, to: output)
                message = count == 0
                    ? "没有“全部问题判是、人工排除”的文章可导出"
                    : "已导出 \(count) 篇 → \(output.lastPathComponent)"
            } catch {
                message = "导出提示词对照失败：\(error.localizedDescription)"
            }
            DispatchQueue.main.async { self.toast = message }
        }
    }

    // ── Background builders ──────────────────────────────────────────────────

    private static func makeBasicStatsBundle(workspace: Workspace, config: AppConfig) -> StatsBundle? {
        guard let db = try? Database(path: workspace.dbPath, config: config) else { return nil }
        var bundle = StatsBundle()
        let currentQuestions = config.classify.questions.filter(\.isCurrent)
        bundle.overview = (try? db.stats(questions: currentQuestions)) ?? [:]
        bundle.sources = (try? db.valueCounts("source")) ?? []
        // 期刊是基础统计的一部分：保留全量，由界面决定搜索、排序和可见范围。
        bundle.journals = (try? db.journalStats()) ?? []

        // 年代图维度：人工复筛结果 + 各分类问题。图例本身由展示层随选择项切换。
        if let reviewed = try? db.yearDimension("include"), !reviewed.isEmpty {
            bundle.yearRaw["include"] = reviewed
            bundle.dimensions.append(StatDimension(label: "人工复筛结果", column: "include"))
        }
        for question in currentQuestions {
            let column = "\(question.id)_ans"
            if let values = try? db.yearDimension(column, afterRowID: question.classifyAfterRowID), !values.isEmpty {
                bundle.yearRaw[column] = values
                bundle.dimensions.append(StatDimension(label: "问题 · \(question.displayName)", column: column))
            }
        }
        return bundle
    }

    private static func makeStatsInsights(
        workspace: Workspace,
        config: AppConfig,
        journals: [JournalStat],
        insights: Set<StatsInsight>
    ) -> StatsBundle? {
        guard let db = try? Database(path: workspace.dbPath, config: config) else { return nil }
        var additions = StatsBundle()
        let currentQuestions = config.classify.questions.filter(\.isCurrent)

        if insights.contains(.promptDistribution) {
            for question in currentQuestions {
                let counts = (try? db.valueCounts(
                    "\(question.id)_ans", afterRowID: question.classifyAfterRowID)) ?? []
                var yes = 0, no = 0, na = 0, pending = 0
                for (value, count) in counts {
                    switch value {
                    case "是": yes += count
                    case "否": no += count
                    case nil: pending += count
                    default: na += count
                    }
                }
                additions.questions.append((question, yes, no, na, pending))
            }
            additions.markLoaded([.promptDistribution])
        }

        if insights.contains(.journalObservations) {
            additions.journalRank = journals.filter { $0.reviewed >= 5 }
                .sorted { ($0.rate, $0.included) > ($1.rate, $1.included) }
            let configuredJournals = Set(EPMCClient.filterQueries(config.download.journals).map { $0.lowercased() })
            additions.suggestAdd = journals.filter {
                !configuredJournals.contains($0.journal.lowercased()) && $0.included >= 2
            }.sorted { $0.included > $1.included }
            additions.suggestPrune = journals.filter {
                configuredJournals.contains($0.journal.lowercased()) && $0.reviewed >= 5 && $0.included == 0
            }.sorted { $0.total > $1.total }
            additions.markLoaded([.journalObservations])
        }

        if insights.contains(.promptAgreement) {
            for question in currentQuestions {
                guard let agreement = try? db.questionAgreement(
                    question.id, afterRowID: question.classifyAfterRowID),
                      agreement.tp + agreement.fp + agreement.fn + agreement.tn > 0 else { continue }
                let falseNegatives =
                    (try? db.disagreementExamples(
                        question.id, aiAnswer: "否", include: "yes", afterRowID: question.classifyAfterRowID)) ?? []
                let falsePositives =
                    (try? db.disagreementExamples(
                        question.id, aiAnswer: "是", include: "no", afterRowID: question.classifyAfterRowID)) ?? []
                additions.agreements.append(QAgreement(
                    question: question,
                    tp: agreement.tp, fp: agreement.fp, fn: agreement.fn, tn: agreement.tn,
                    falseNeg: falseNegatives, falsePos: falsePositives
                ))
            }
            additions.promptCombinedEvaluation =
                (try? db.promptCombinedEvaluation(
                    questions: config.classify.questions.filter(\.isActiveForClassification)))
                ?? PromptCombinedEvaluation()
            additions.markLoaded([.promptAgreement])
        }

        if insights.contains(.keywordTerms) {
            additions.channelMapBuilt = ((try? db.articleTermsCount()) ?? 0) > 0
            additions.keywordTerms = (try? db.keywordTermStats()) ?? []
            additions.markLoaded([.keywordTerms])
        }

        return additions
    }
}

private extension StatsBundle {
    mutating func apply(insights additions: StatsBundle) {
        let loaded = additions.loadedInsights
        if loaded.contains(.promptDistribution) { questions = additions.questions }
        if loaded.contains(.journalObservations) {
            journalRank = additions.journalRank
            suggestAdd = additions.suggestAdd
            suggestPrune = additions.suggestPrune
        }
        if loaded.contains(.promptAgreement) {
            agreements = additions.agreements
            promptCombinedEvaluation = additions.promptCombinedEvaluation
        }
        if loaded.contains(.keywordTerms) {
            keywordTerms = additions.keywordTerms
            channelMapBuilt = additions.channelMapBuilt
        }
        markLoaded(loaded)
    }
}

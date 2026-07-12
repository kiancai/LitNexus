import Foundation

// Pipeline orchestration behavior for AppState.

extension AppState {
    // ── 跑流水线（后台线程）─────────────────────────────────────────────────────

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 600 { logLines.removeFirst(logLines.count - 600) }
    }

    /// Adds an event to the current run.  Only legacy technical text is mirrored
    /// into `logLines` while older diagnostics consumers still exist.
    private func appendRunRecord(_ event: PipelineEvent, stepID: String?) {
        runRecords.append(RunRecord(stepID: stepID, event: event))
        if runRecords.count > 600 { runRecords.removeFirst(runRecords.count - 600) }

        guard let technicalText = event.technicalText else { return }
        let legacyLine = event.level == .warning ? "⚠ \(technicalText)" : technicalText
        appendLog(legacyLine)
    }

    // 把告警挂到当前正在跑的步骤上（时间线以琥珀色显示，最多累计几条）。
    private func appendWarning(_ msg: String, stepID: String) {
        guard let i = steps.firstIndex(where: { $0.id == stepID }) else { return }
        let lines = steps[i].warning.isEmpty ? [] : steps[i].warning.components(separatedBy: "\n")
        if lines.count >= 3 {
            steps[i].warning = lines.prefix(2).joined(separator: "\n") + "\n…等更多告警见运行日志"
        } else {
            steps[i].warning = (lines + [msg]).joined(separator: "\n")
        }
    }

    private func setStep(_ id: String, _ status: StepStatus, _ detail: String) {
        if let i = steps.firstIndex(where: { $0.id == id }) {
            steps[i].status = status
            steps[i].detail = detail
            steps[i].current = 0
            steps[i].total = 0
            steps[i].eta = ""
            steps[i].warning = ""
            steps[i].startedAt = nil
            steps[i].etaDeadline = nil
            steps[i].subs = []
        }
    }

    private func updateSub(key: String, label: String, current: Int, total: Int, item: String) {
        guard let id = currentStepID, let i = steps.firstIndex(where: { $0.id == id }) else { return }
        let tkey = "\(id):\(key)"
        if subStartTimes[tkey] == nil { subStartTimes[tkey] = Date() }
        // 跑完即冻结已用时间，避免完成后继续走（期刊跑完仍在涨、摘要把标题计时带着跑）
        if total > 0, current >= total, subEndTimes[tkey] == nil { subEndTimes[tkey] = Date() }
        var eta = ""
        var deadline: Date? = nil
        // 下载的预估很不准（各检索式命中差异大），只显示正计时、不显示倒计时
        if id != "download", let start = subStartTimes[tkey], current > 0, total > current {
            let remaining = Date().timeIntervalSince(start) / Double(current) * Double(total - current)
            eta = AppState.formatETA(remaining)
            deadline = Date().addingTimeInterval(remaining)
        }
        let sub = SubProgress(key: key, label: label, current: current, total: total, item: item,
                              eta: eta, startedAt: subStartTimes[tkey], endedAt: subEndTimes[tkey],
                              etaDeadline: deadline)
        if let j = steps[i].subs.firstIndex(where: { $0.key == key }) { steps[i].subs[j] = sub }
        else { steps[i].subs.append(sub) }
    }

    func resetSteps() {
        for i in steps.indices { setStep(steps[i].id, .idle, "") }
    }

    private func startStep(_ id: String) {
        currentStepID = id
        stepStartTime = Date()
        setStep(id, .running, "")
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].startedAt = stepStartTime }
        appendRunRecord(.stepStarted(stepID: id), stepID: id)
    }

    private func updateProgress(completed: Int, total: Int) {
        guard let id = currentStepID, let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].current = completed
        steps[i].total = total
        if id != "download", let start = stepStartTime, completed > 0, total > completed {
            let elapsed = Date().timeIntervalSince(start)
            let remaining = elapsed / Double(completed) * Double(total - completed)
            steps[i].eta = AppState.formatETA(remaining)
            steps[i].etaDeadline = Date().addingTimeInterval(remaining)
        } else {
            steps[i].eta = ""
            steps[i].etaDeadline = nil
        }
    }

    private static func formatETA(_ seconds: Double) -> String {
        if seconds < 1 { return "" }
        let s = Int(seconds.rounded())
        if s < 60 { return "约 \(s) 秒" }
        let m = s / 60, sec = s % 60
        return sec == 0 ? "约 \(m) 分钟" : "约 \(m) 分 \(sec) 秒"
    }

    // 完成耗时（友好措辞）。
    static func formatDuration(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        if t < 60 { return "\(t) 秒" }
        let m = t / 60, sec = t % 60
        return sec == 0 ? "\(m) 分钟" : "\(m) 分 \(sec) 秒"
    }

    // 进度计时器用的紧凑 mm:ss（仿标准下载进度）。
    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// 按 id 顺序执行步骤，逐步更新每步状态与进度；任一步失败则停止并标红。
    /// single=true 表示单独运行（高级操作），对每一步都二次确认。
    func run(_ ids: [String], single: Bool = false) {
        guard let ws = workspace, !isRunning else { return }
        let cfg = config
        let mode = downloadMode, days = downloadDays
        for id in ids { setStep(id, .idle, "") }
        runRecords = []
        logLines = []
        subStartTimes = [:]
        subEndTimes = [:]
        let token = CancelToken()
        cancelToken = token
        isCancelling = false
        isRunning = true
        DispatchQueue.global().async {
            for id in ids {
                if token.isCancelled { break }   // 步骤之间也可中止
                // 二次确认：单独运行的任意步骤，或自动流程里的 AI 步骤（翻译/分类），除非已勾「默认同意」
                if self.needsConfirm(id, single: single), !self.isAutoApproved(id) {
                    let approved = self.requestConfirmSync(stepID: id, cfg: cfg, ws: ws, mode: mode, days: days)
                    if !approved {
                        DispatchQueue.main.async {
                            self.setStep(id, .idle, "已取消")
                            self.appendRunRecord(.stepCancelled(stepID: id, reason: "confirmation_declined"), stepID: id)
                        }
                        break
                    }
                }

                let stepStartedAt = Date()
                let reporter = UIReporter(
                    onEvent: { event in
                        DispatchQueue.main.async { self.appendRunRecord(event, stepID: id) }
                    },
                    onProgress: { c, t in
                        DispatchQueue.main.async { self.updateProgress(completed: c, total: t) }
                    },
                    onSub: { k, l, c, t, it in
                        DispatchQueue.main.async { self.updateSub(key: k, label: l, current: c, total: t, item: it) }
                    },
                    onWarn: { msg in
                        DispatchQueue.main.async { self.appendWarning(msg, stepID: id) }
                    },
                    token: token
                )
                DispatchQueue.main.async { self.startStep(id) }
                do {
                    let result = try AppState.work(id: id, cfg: cfg, ws: ws, mode: mode, days: days, reporter: reporter)
                    let duration = Date().timeIntervalSince(stepStartedAt)
                    DispatchQueue.main.async {
                        var detail = result
                        if duration >= 1 { detail += " · 耗时 \(AppState.formatDuration(duration))" }
                        self.setStep(id, .success, detail)
                        self.appendRunRecord(.stepSucceeded(stepID: id, duration: duration, technicalResult: result), stepID: id)
                    }
                } catch is PipelineCancelled {
                    DispatchQueue.main.async {
                        self.setStep(id, .idle, "已中止")
                        self.appendRunRecord(.stepCancelled(stepID: id, reason: "cancel_requested"), stepID: id)
                    }
                    break
                } catch {
                    DispatchQueue.main.async {
                        self.setStep(id, .failed, error.localizedDescription)
                        self.appendRunRecord(.stepFailed(stepID: id, error: error), stepID: id)
                    }
                    break
                }
            }
            DispatchQueue.main.async {
                self.currentStepID = nil
                self.isRunning = false
                self.isCancelling = false
                self.cancelToken = nil
                self.refreshStats()
            }
        }
    }

    func runAll() { run(["download", "merge", "translate", "classify"]) }
    func runOne(_ id: String) { run([id], single: true) }

    /// 请求中止：置位令牌，引擎在最近的安全检查点干净停止。
    func cancelRun() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        cancelToken?.cancel()
        appendRunRecord(.cancellationRequested(stepID: currentStepID), stepID: currentStepID)
    }

    // ── 二次确认门控 ────────────────────────────────────────────────────────────

    private func needsConfirm(_ id: String, single: Bool) -> Bool {
        single || id == "translate" || id == "classify"
    }

    func setAppearance(_ a: AppAppearance) {
        appearance = a
        UserDefaults.standard.set(a.rawValue, forKey: "appearance")
    }

    func isAutoApproved(_ id: String) -> Bool {
        UserDefaults.standard.bool(forKey: "autoApprove_\(id)")
    }
    func setAutoApproved(_ id: String, _ on: Bool) {
        objectWillChange.send()
        UserDefaults.standard.set(on, forKey: "autoApprove_\(id)")
    }
    /// 是否有任一 AI 步骤已设为「默认同意」（用于在高级操作里显示「恢复询问」）。
    var hasAutoApproved: Bool { isAutoApproved("translate") || isAutoApproved("classify") }

    /// 阻塞当前后台线程，弹出确认；用户响应后再放行。返回是否批准。
    private func requestConfirmSync(stepID: String, cfg: AppConfig, ws: Workspace,
                                    mode: String, days: Int) -> Bool {
        let (title, message) = AppState.confirmText(stepID: stepID, cfg: cfg, ws: ws, mode: mode, days: days)
        let sem = DispatchSemaphore(value: 0)
        var approved = false
        DispatchQueue.main.async {
            self.pendingConfirm = PendingConfirm(stepID: stepID, title: title, message: message) { ok, remember in
                if remember { self.setAutoApproved(stepID, true) }
                approved = ok
                self.pendingConfirm = nil
                sem.signal()
            }
        }
        sem.wait()
        return approved
    }

    /// 生成确认文案，含将要处理的规模（查询数据库估算）。
    private static func confirmText(stepID: String, cfg: AppConfig, ws: Workspace,
                                    mode: String, days: Int) -> (String, String) {
        let db = try? Database(path: ws.dbPath, config: cfg)
        func count(_ block: (Database) throws -> Int) -> Int {
            guard let db else { return 0 }
            return (try? block(db)) ?? 0
        }
        switch stepID {
        case "download":
            let m = ["all": "期刊 + 关键词", "journals": "仅期刊", "keywords": "仅关键词"][mode] ?? mode
            return ("确认下载文献", "将按检索范围「\(m)」抓取最近 \(days) 天的文献。")
        case "merge":
            let n = ((try? FileManager.default.contentsOfDirectory(at: ws.downloadsDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }.count
            return ("确认合并入库", "将把 downloads 下的 \(n) 个新文件解析去重后写入数据库。")
        case "translate":
            let t = count { try $0.fetchPendingTranslations(textColumn: "title", zhColumn: "title_zh").count }
            let absText: String
            if cfg.translate.translateAbstract {
                let a = count { try $0.fetchPendingTranslations(textColumn: "abstract", zhColumn: "abstract_zh").count }
                absText = "、\(a) 篇摘要"
            } else { absText = "" }
            return ("确认翻译标题与摘要", "将调用 AI 翻译 \(t) 篇标题\(absText)。该操作会消耗 API 额度。")
        case "classify":
            let active = cfg.classify.questions.filter(\.isActiveForClassification)
            // 不同“仅未来”边界的问题必须分开取待办；把它们一并传给数据库会
            // 错误地把新问题套到历史文章上。确认文案用去重后的文章数，避免同一篇
            // 文章因多个问题范围而被重复报数。
            let pendingIDs: Set<String>
            if let db {
                let groups = Dictionary(grouping: active, by: \.classificationScopeKey)
                var ids = Set<String>()
                for group in groups.values {
                    let rows = (try? db.fetchPendingClassification(group)) ?? []
                    ids.formUnion(rows.map(\.epmcID))
                }
                pendingIDs = ids
            } else {
                pendingIDs = []
            }
            return ("确认智能分类", "将处理 \(pendingIDs.count) 篇待分类文章，按 \(active.count) 个当前问题的适用范围执行 AI 分类。该操作会消耗 API 额度。")
        default:
            return ("确认操作", "确认执行该步骤？")
        }
    }

    private static func work(id: String, cfg: AppConfig, ws: Workspace, mode: String, days: Int,
                             reporter: ProgressReporter) throws -> String {
        switch id {
        case "download": return try Pipeline.doDownload(config: cfg, workspace: ws, mode: mode, days: days, reporter: reporter)
        case "merge": return try Pipeline.doMerge(config: cfg, workspace: ws, reporter: reporter)
        case "translate": return try Pipeline.doTranslate(config: cfg, workspace: ws, reporter: reporter)
        case "classify": return try Pipeline.doClassify(config: cfg, workspace: ws, reporter: reporter)
        default: return ""
        }
    }
}

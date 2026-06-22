import Foundation
import SwiftUI

enum Route { case chooser, setup, main }
enum Page: String, CaseIterable { case run = "运行", data = "数据", stats = "统计", settings = "配置" }

// ── 统计页数据 ──────────────────────────────────────────────────────────────

struct StatDimension: Identifiable, Equatable { var id: String { column }; let label: String; let column: String }

struct StatsBundle {
    var overview: [String: Int] = [:]
    var dimensions: [StatDimension] = []                                       // 年代图可选维度
    var yearRaw: [String: [(year: Int, value: String?, count: Int)]] = [:]     // column -> 原始分组
    var sources: [(value: String?, count: Int)] = []
    var questions: [(question: Question, yes: Int, no: Int, na: Int, pending: Int)] = []
    var topJournals: [(value: String, count: Int)] = []
}

enum StepStatus { case idle, running, success, failed }

struct SubProgress: Identifiable, Equatable {
    let key: String
    var id: String { key }
    var label: String
    var current: Int
    var total: Int
    var item: String
    var progress: Double? { total > 0 ? min(1, Double(current) / Double(total)) : nil }
}

struct PipelineStep: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    var status: StepStatus = .idle
    var detail: String = ""
    var current: Int = 0
    var total: Int = 0
    var eta: String = ""
    var subs: [SubProgress] = []
    var progress: Double? { total > 0 ? min(1, Double(current) / Double(total)) : nil }
}

// 把引擎进度上报转发到界面（日志 + 进度 + 子进度，回主线程更新）。
final class UIReporter: ProgressReporter {
    private let onLog: (String) -> Void
    private let onProgress: (_ completed: Int, _ total: Int) -> Void
    private let onSub: (_ key: String, _ label: String, _ current: Int, _ total: Int, _ item: String) -> Void
    private var total = 0
    private var completed = 0

    init(onLog: @escaping (String) -> Void,
         onProgress: @escaping (Int, Int) -> Void,
         onSub: @escaping (String, String, Int, Int, String) -> Void) {
        self.onLog = onLog
        self.onProgress = onProgress
        self.onSub = onSub
    }
    func addTask(_ description: String, total: Int?) -> Int {
        self.total = total ?? 0
        self.completed = 0
        onLog(total.map { "\(description)（共 \($0)）" } ?? description)
        onProgress(0, self.total)
        return 0
    }
    func update(_ taskID: Int, advance: Int) {
        completed += advance
        onProgress(completed, total)
    }
    func complete(_ taskID: Int) {}
    func log(_ message: String) { onLog(message) }
    func subProgress(key: String, label: String, current: Int, total: Int, item: String) {
        onSub(key, label, current, total, item)
    }
}

// 运行 AI 步骤前的二次确认请求。
struct PendingConfirm: Identifiable {
    let id = UUID()
    let stepID: String
    let title: String
    let message: String
    let onResult: (_ approved: Bool, _ remember: Bool) -> Void
}

final class AppState: ObservableObject {
    @Published var workspace: Workspace?
    @Published var config = AppConfig()
    @Published var route: Route = .chooser
    @Published var page: Page = .run
    @Published var logLines: [String] = []
    @Published var isRunning = false
    @Published var stats: [String: Int] = [:]
    @Published var toast: String?
    @Published var pendingConfirm: PendingConfirm?

    @Published var downloadMode = "all"
    @Published var downloadDays = 30
    @Published var steps: [PipelineStep] = [
        PipelineStep(id: "download", name: "下载文献", subtitle: "从 Europe PMC 按期刊/关键词抓取"),
        PipelineStep(id: "merge", name: "合并入库", subtitle: "解析并去重写入数据库"),
        PipelineStep(id: "translate", name: "翻译标题与摘要", subtitle: "调用 AI 批量翻译标题与摘要"),
        PipelineStep(id: "classify", name: "智能分类", subtitle: "调用 AI 按问题初筛"),
    ]

    init() {
        if let ws = try? WorkspaceStore.resolve() {
            openExisting(ws)
        }
    }

    var needsSetup: Bool { config.activeProfile?.isComplete != true }

    // ── AI 方案管理（增删选立即持久化）─────────────────────────────────────────

    @discardableResult
    func addAIProfile() -> String {
        let p = AIProfile(name: "方案 \(config.aiProfiles.count + 1)")
        config.aiProfiles.append(p)
        config.activeAIID = p.id
        persistConfig()
        return p.id
    }

    func updateAIProfile(_ profile: AIProfile) {
        if let i = config.aiProfiles.firstIndex(where: { $0.id == profile.id }) {
            config.aiProfiles[i] = profile
            persistConfig()
        }
    }

    func deleteAIProfile(_ id: String) {
        config.aiProfiles.removeAll { $0.id == id }
        if config.activeAIID == id { config.activeAIID = config.aiProfiles.first?.id ?? "" }
        persistConfig()
    }

    func selectAIProfile(_ id: String) {
        config.activeAIID = id
        persistConfig()
    }

    func persistConfig() {
        guard let ws = workspace else { return }
        try? ConfigStore.save(config, to: ws.configPath)
    }

    // ── 分类问题管理（增删改即时持久化，仿 AI 方案）─────────────────────────────

    @discardableResult
    func addQuestion() -> String {
        let id = config.classify.nextQuestionID()
        config.classify.questions.append(Question(id: id, nickname: "", text: "", classify: true, export: true))
        persistConfig()
        if let ws = workspace { _ = try? Database(path: ws.dbPath, config: config) }  // 补齐新问题的动态列
        return id
    }

    /// 当前某问题的可写绑定（编辑即写内存并持久化）。
    func questionBinding(_ id: String) -> Binding<Question>? {
        guard let idx = config.classify.questions.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.config.classify.questions[idx] },
            set: { self.config.classify.questions[idx] = $0; self.persistConfig() }
        )
    }

    /// 永久删除问题：从配置移除 + DROP 掉 {id}_ans/{id}_rea 两列及数据。不可恢复。
    func deleteQuestionPermanently(_ id: String) {
        config.classify.questions.removeAll { $0.id == id }
        persistConfig()
        if let ws = workspace {
            try? Database(path: ws.dbPath, config: config).dropQuestionColumns(id)
        }
        refreshStats()
    }

    /// 当前选中方案的可写绑定（编辑即写入内存并持久化）。
    func activeProfileBinding() -> Binding<AIProfile>? {
        guard let idx = config.aiProfiles.firstIndex(where: { $0.id == config.activeAIID }) else { return nil }
        return Binding(
            get: { self.config.aiProfiles[idx] },
            set: { self.config.aiProfiles[idx] = $0; self.persistConfig() }
        )
    }

    // ── 工作区 ────────────────────────────────────────────────────────────────

    func openOrCreate(_ url: URL) {
        do {
            let ws = try WorkspaceStore.create(url)
            workspace = ws
            config = (try? ConfigStore.load(ws.configPath)) ?? AppConfig()
            route = needsSetup ? .setup : .main
            page = .run
            logLines = []
            downloadDays = config.download.days
            resetSteps()
            refreshStats()
        } catch {
            toast = "无法打开项目：\(error.localizedDescription)"
        }
    }

    private func openExisting(_ ws: Workspace) {
        workspace = ws
        config = (try? ConfigStore.load(ws.configPath)) ?? AppConfig()
        route = needsSetup ? .setup : .main
        downloadDays = config.download.days
        refreshStats()
    }

    func switchProject() {
        workspace = nil
        route = .chooser
        logLines = []
        stats = [:]
    }

    func finishSetup() {
        route = needsSetup ? .setup : .main
        refreshStats()
    }

    // ── 保存配置 + 检索列表 ─────────────────────────────────────────────────────

    /// 自动保存设置与检索列表（静默，不弹提示）。保留 AI 方案不被覆盖由调用方负责。
    func saveConfig(_ cfg: AppConfig, journals: String, keywords: String) {
        guard let ws = workspace else { return }
        do {
            try journals.write(to: ws.journalsFile, atomically: true, encoding: .utf8)
            try keywords.write(to: ws.root.appendingPathComponent("keywords.txt"), atomically: true, encoding: .utf8)
            try ConfigStore.save(cfg, to: ws.configPath)
            _ = try Database(path: ws.dbPath, config: cfg)  // 补齐动态列
            config = cfg
            refreshStats()
        } catch {
            toast = "保存失败：\(error.localizedDescription)"
        }
    }

    func readJournals() -> String { (try? String(contentsOf: workspace?.journalsFile ?? URL(fileURLWithPath: "/"), encoding: .utf8)) ?? "" }
    func readKeywords() -> String {
        guard let ws = workspace else { return "" }
        return (try? String(contentsOf: ws.root.appendingPathComponent("keywords.txt"), encoding: .utf8)) ?? ""
    }

    // ── 统计 ──────────────────────────────────────────────────────────────────

    func refreshStats() {
        guard let ws = workspace, FileManager.default.fileExists(atPath: ws.dbPath.path) else {
            stats = [:]; return
        }
        let cfg = config
        DispatchQueue.global().async {
            let s = (try? Database(path: ws.dbPath, config: cfg).stats(questions: cfg.classify.questions)) ?? [:]
            DispatchQueue.main.async { self.stats = s }
        }
    }

    // ── 跑流水线（后台线程）─────────────────────────────────────────────────────

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 600 { logLines.removeFirst(logLines.count - 600) }
    }

    private var currentStepID: String?
    private var stepStartTime: Date?

    private func setStep(_ id: String, _ status: StepStatus, _ detail: String) {
        if let i = steps.firstIndex(where: { $0.id == id }) {
            steps[i].status = status
            steps[i].detail = detail
            steps[i].current = 0
            steps[i].total = 0
            steps[i].eta = ""
            steps[i].subs = []
        }
    }

    private func updateSub(key: String, label: String, current: Int, total: Int, item: String) {
        guard let id = currentStepID, let i = steps.firstIndex(where: { $0.id == id }) else { return }
        let sub = SubProgress(key: key, label: label, current: current, total: total, item: item)
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
    }

    private func updateProgress(completed: Int, total: Int) {
        guard let id = currentStepID, let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].current = completed
        steps[i].total = total
        if let start = stepStartTime, completed > 0, total > completed {
            let elapsed = Date().timeIntervalSince(start)
            let remaining = elapsed / Double(completed) * Double(total - completed)
            steps[i].eta = AppState.formatETA(remaining)
        } else {
            steps[i].eta = ""
        }
    }

    private static func formatETA(_ seconds: Double) -> String {
        if seconds < 1 { return "" }
        let s = Int(seconds.rounded())
        if s < 60 { return "约 \(s) 秒" }
        let m = s / 60, sec = s % 60
        return sec == 0 ? "约 \(m) 分钟" : "约 \(m) 分 \(sec) 秒"
    }

    /// 按 id 顺序执行步骤，逐步更新每步状态与进度；任一步失败则停止并标红。
    /// single=true 表示单独运行（高级操作），对每一步都二次确认。
    func run(_ ids: [String], single: Bool = false) {
        guard let ws = workspace, !isRunning else { return }
        let cfg = config
        let mode = downloadMode, days = downloadDays
        for id in ids { setStep(id, .idle, "") }
        logLines = []
        isRunning = true
        DispatchQueue.global().async {
            let reporter = UIReporter(
                onLog: { line in DispatchQueue.main.async { self.appendLog(line) } },
                onProgress: { c, t in DispatchQueue.main.async { self.updateProgress(completed: c, total: t) } },
                onSub: { k, l, c, t, it in DispatchQueue.main.async { self.updateSub(key: k, label: l, current: c, total: t, item: it) } }
            )
            for id in ids {
                // 二次确认：单独运行的任意步骤，或自动流程里的 AI 步骤（翻译/分类），除非已勾「默认同意」
                if self.needsConfirm(id, single: single), !self.isAutoApproved(id) {
                    let approved = self.requestConfirmSync(stepID: id, cfg: cfg, ws: ws, mode: mode, days: days)
                    if !approved {
                        DispatchQueue.main.async { self.setStep(id, .idle, "已取消") }
                        break
                    }
                }
                DispatchQueue.main.async { self.startStep(id) }
                do {
                    let result = try AppState.work(id: id, cfg: cfg, ws: ws, mode: mode, days: days, reporter: reporter)
                    DispatchQueue.main.async { self.setStep(id, .success, result) }
                } catch {
                    DispatchQueue.main.async { self.setStep(id, .failed, error.localizedDescription) }
                    break
                }
            }
            DispatchQueue.main.async {
                self.currentStepID = nil
                self.isRunning = false
                self.refreshStats()
            }
        }
    }

    func runAll() { run(["download", "merge", "translate", "classify"]) }
    func runOne(_ id: String) { run([id], single: true) }

    // ── 二次确认门控 ────────────────────────────────────────────────────────────

    private func needsConfirm(_ id: String, single: Bool) -> Bool {
        single || id == "translate" || id == "classify"
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
            let active = cfg.classify.questions.filter { $0.classify }
            let pending = count { try $0.fetchPendingClassification(active).count }
            return ("确认智能分类", "将对 \(pending) 篇文章执行 \(active.count) 个问题的 AI 分类。该操作会消耗 API 额度。")
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

    // ── 导出 / 导入 ─────────────────────────────────────────────────────────────

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

    func importCSV(_ url: URL) {
        guard let ws = workspace else { return }
        let cfg = config
        DispatchQueue.global().async {
            let msg: String
            do {
                let db = try Database(path: ws.dbPath, config: cfg)
                let (upd, unm, tot) = try ArticleIO.importReviewedCSV(db, csvPath: url, annotationColumns: cfg.schema.customColumns)
                msg = "导入完成：更新 \(upd)，未匹配 \(unm)，共 \(tot) 行"
            } catch { msg = "导入失败：\(error.localizedDescription)" }
            DispatchQueue.main.async { self.toast = msg; self.refreshStats() }
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

    /// 从另一份 .db 合并导入文章。导入前自动备份为 .db.bak。
    func importDatabase(from source: URL, strategy: Database.ImportStrategy = .skipExisting) {
        guard let ws = workspace else { return }
        let cfg = config
        DispatchQueue.global().async {
            let msg: String
            do {
                let db = try Database(path: ws.dbPath, config: cfg)
                let bak = try db.backup()  // 风险操作前快照
                let (ins, skip, total) = try db.importFromDatabase(source, strategy: strategy)
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

    // ── 统计页数据计算 ──────────────────────────────────────────────────────────

    func computeStats(_ completion: @escaping (StatsBundle?) -> Void) {
        guard let ws = workspace, FileManager.default.fileExists(atPath: ws.dbPath.path) else {
            completion(nil); return
        }
        let cfg = config
        DispatchQueue.global().async {
            guard let db = try? Database(path: ws.dbPath, config: cfg) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            var b = StatsBundle()
            b.overview = (try? db.stats(questions: cfg.classify.questions)) ?? [:]
            b.sources = (try? db.valueCounts("source")) ?? []
            b.topJournals = (try? db.topValues("journal_title", limit: 10)) ?? []

            // 年代图维度：复筛纳入 + 各问题
            if let inc = try? db.yearDimension("include"), !inc.isEmpty {
                b.yearRaw["include"] = inc
                b.dimensions.append(StatDimension(label: "复筛纳入", column: "include"))
            }
            for q in cfg.classify.questions {
                let col = "\(q.id)_ans"
                if let yd = try? db.yearDimension(col), !yd.isEmpty {
                    b.yearRaw[col] = yd
                    b.dimensions.append(StatDimension(label: q.displayName, column: col))
                }
            }

            // 各问题筛选概况（是/否/N-A/未分类）
            for q in cfg.classify.questions {
                let counts = (try? db.valueCounts("\(q.id)_ans")) ?? []
                var yes = 0, no = 0, na = 0, pending = 0
                for (v, c) in counts {
                    switch v {
                    case "是": yes += c
                    case "否": no += c
                    case nil: pending += c
                    default: na += c
                    }
                }
                b.questions.append((q, yes, no, na, pending))
            }

            DispatchQueue.main.async { completion(b) }
        }
    }

    // ── 测试 AI 连接 ────────────────────────────────────────────────────────────

    func testAIConnection(_ ai: AIConfig, completion: @escaping (Bool, String) -> Void) {
        guard !ai.apiKey.isEmpty else { completion(false, "请填写 API Key"); return }
        guard !ai.baseURL.isEmpty, !ai.model.isEmpty else { completion(false, "请填写接口地址与模型名称"); return }
        DispatchQueue.global().async {
            do {
                _ = try AIClient.chat(ai: ai, system: "ping", user: "ping", temperature: 0)
                DispatchQueue.main.async { completion(true, "连接成功") }
            } catch {
                DispatchQueue.main.async { completion(false, "连接失败：\(error.localizedDescription)") }
            }
        }
    }
}

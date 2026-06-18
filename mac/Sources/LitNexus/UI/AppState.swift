import Foundation
import SwiftUI

enum Route { case chooser, setup, main }
enum Page: String, CaseIterable { case run = "运行", data = "数据", settings = "配置" }

enum StepStatus { case idle, running, success, failed }

struct PipelineStep: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    var status: StepStatus = .idle
    var detail: String = ""
    var current: Int = 0
    var total: Int = 0
    var eta: String = ""
    var progress: Double? { total > 0 ? min(1, Double(current) / Double(total)) : nil }
}

// 把引擎进度上报转发到界面（日志 + 进度，回主线程更新）。
final class UIReporter: ProgressReporter {
    private let onLog: (String) -> Void
    private let onProgress: (_ completed: Int, _ total: Int) -> Void
    private var total = 0
    private var completed = 0

    init(onLog: @escaping (String) -> Void, onProgress: @escaping (Int, Int) -> Void) {
        self.onLog = onLog
        self.onProgress = onProgress
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

    @Published var downloadMode = "all"
    @Published var downloadDays = 30
    @Published var steps: [PipelineStep] = [
        PipelineStep(id: "download", name: "下载文献", subtitle: "从 Europe PMC 按期刊/关键词抓取"),
        PipelineStep(id: "merge", name: "合并入库", subtitle: "解析并去重写入数据库"),
        PipelineStep(id: "translate", name: "翻译标题", subtitle: "调用 AI 批量翻译标题"),
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
        }
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
    func run(_ ids: [String]) {
        guard let ws = workspace, !isRunning else { return }
        let cfg = config
        let mode = downloadMode, days = downloadDays
        for id in ids { setStep(id, .idle, "") }
        logLines = []
        isRunning = true
        DispatchQueue.global().async {
            let reporter = UIReporter(
                onLog: { line in DispatchQueue.main.async { self.appendLog(line) } },
                onProgress: { c, t in DispatchQueue.main.async { self.updateProgress(completed: c, total: t) } }
            )
            for id in ids {
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
    func runOne(_ id: String) { run([id]) }

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

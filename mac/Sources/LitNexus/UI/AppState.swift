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
}

// 把引擎进度上报转发到界面日志（线程安全，回主线程更新）。
final class UILogReporter: ProgressReporter {
    private let append: (String) -> Void
    init(_ append: @escaping (String) -> Void) { self.append = append }
    func addTask(_ description: String, total: Int?) -> Int {
        append(total.map { "\(description)（共 \($0)）" } ?? description); return 0
    }
    func update(_ taskID: Int, advance: Int) {}
    func complete(_ taskID: Int) {}
    func log(_ message: String) { append(message) }
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

    var needsSetup: Bool { config.ai.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        || config.ai.model.trimmingCharacters(in: .whitespaces).isEmpty }

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

    func saveConfig(_ cfg: AppConfig, journals: String, keywords: String) {
        guard let ws = workspace else { return }
        do {
            try journals.write(to: ws.journalsFile, atomically: true, encoding: .utf8)
            try keywords.write(to: ws.root.appendingPathComponent("keywords.txt"), atomically: true, encoding: .utf8)
            try ConfigStore.save(cfg, to: ws.configPath)
            _ = try Database(path: ws.dbPath, config: cfg)  // 补齐动态列
            config = cfg
            toast = "配置已保存"
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

    private func setStep(_ id: String, _ status: StepStatus, _ detail: String) {
        if let i = steps.firstIndex(where: { $0.id == id }) {
            steps[i].status = status
            steps[i].detail = detail
        }
    }

    func resetSteps() {
        for i in steps.indices { steps[i].status = .idle; steps[i].detail = "" }
    }

    /// 按 id 顺序执行步骤，逐步更新每步状态；任一步失败则停止并标红。
    func run(_ ids: [String]) {
        guard let ws = workspace, !isRunning else { return }
        let cfg = config
        let mode = downloadMode, days = downloadDays
        for id in ids { setStep(id, .idle, "") }
        logLines = []
        isRunning = true
        DispatchQueue.global().async {
            let reporter = UILogReporter { line in DispatchQueue.main.async { self.appendLog(line) } }
            for id in ids {
                DispatchQueue.main.async { self.setStep(id, .running, "") }
                do {
                    let result = try AppState.work(id: id, cfg: cfg, ws: ws, mode: mode, days: days, reporter: reporter)
                    DispatchQueue.main.async { self.setStep(id, .success, result) }
                } catch {
                    DispatchQueue.main.async { self.setStep(id, .failed, error.localizedDescription) }
                    break
                }
            }
            DispatchQueue.main.async {
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
        let resolved = AppConfig(ai: ai).resolvedAI
        guard !resolved.apiKey.isEmpty else { completion(false, "未填写 API Key"); return }
        guard !resolved.baseURL.isEmpty, !resolved.model.isEmpty else { completion(false, "请先填写 Base URL 和模型名"); return }
        DispatchQueue.global().async {
            do {
                _ = try AIClient.chat(ai: resolved, system: "ping", user: "ping", temperature: 0)
                DispatchQueue.main.async { completion(true, "连接成功") }
            } catch {
                DispatchQueue.main.async { completion(false, "连接失败：\(error.localizedDescription)") }
            }
        }
    }
}

extension AppConfig {
    init(ai: AIConfig) { self.init(); self.ai = ai }
}

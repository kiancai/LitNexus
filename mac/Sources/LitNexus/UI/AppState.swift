import Foundation
import SwiftUI

enum Route { case chooser, setup, main }
enum Page: String, CaseIterable { case run = "运行", data = "数据", settings = "配置" }

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
            refreshStats()
        } catch {
            toast = "无法打开项目：\(error.localizedDescription)"
        }
    }

    private func openExisting(_ ws: Workspace) {
        workspace = ws
        config = (try? ConfigStore.load(ws.configPath)) ?? AppConfig()
        route = needsSetup ? .setup : .main
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

    /// 在后台依次执行若干步骤；每步 work 接到 reporter，返回结果摘要。
    func runSteps(_ steps: [(name: String, work: (AppConfig, Workspace, ProgressReporter) throws -> String)]) {
        guard let ws = workspace, !isRunning else { return }
        let cfg = config
        isRunning = true
        DispatchQueue.global().async {
            let reporter = UILogReporter { line in DispatchQueue.main.async { self.appendLog(line) } }
            for step in steps {
                DispatchQueue.main.async { self.appendLog("▶ 开始：\(step.name)") }
                do {
                    let result = try step.work(cfg, ws, reporter)
                    DispatchQueue.main.async { self.appendLog("✓ 完成：\(step.name)  \(result)") }
                } catch {
                    DispatchQueue.main.async { self.appendLog("✗ 失败：\(step.name)：\(error.localizedDescription)") }
                    break
                }
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.refreshStats()
            }
        }
    }

    func runDownload(mode: String, days: Int) {
        runSteps([("下载", { c, w, r in try Pipeline.doDownload(config: c, workspace: w, mode: mode, days: days, reporter: r) })])
    }
    func runMerge() { runSteps([("合并入库", { c, w, r in try Pipeline.doMerge(config: c, workspace: w, reporter: r) })]) }
    func runTranslate() { runSteps([("翻译标题", { c, w, r in try Pipeline.doTranslate(config: c, workspace: w, reporter: r) })]) }
    func runClassify() { runSteps([("AI 分类", { c, w, r in try Pipeline.doClassify(config: c, workspace: w, reporter: r) })]) }

    func runAll(mode: String, days: Int) {
        runSteps([
            ("下载", { c, w, r in try Pipeline.doDownload(config: c, workspace: w, mode: mode, days: days, reporter: r) }),
            ("合并入库", { c, w, r in try Pipeline.doMerge(config: c, workspace: w, reporter: r) }),
            ("翻译标题", { c, w, r in try Pipeline.doTranslate(config: c, workspace: w, reporter: r) }),
            ("AI 分类", { c, w, r in try Pipeline.doClassify(config: c, workspace: w, reporter: r) }),
        ])
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

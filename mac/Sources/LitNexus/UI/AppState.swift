import Foundation
import SwiftUI

/// Shared UI state for the active LitNexus window.
///
/// Behavior is organized in focused extensions under `UI/AppState/`; this file
/// deliberately owns only the observable state and application lifecycle.
final class AppState: ObservableObject {
    @Published var workspace: Workspace?
    @Published var config = AppConfig()
    @Published var route: Route = .chooser
    @Published var page: Page = .run
    @Published var appearance: AppAppearance =
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "system") ?? .system
    @Published var runRecords: [RunRecord] = []
    // Retained temporarily for compatibility with older UI surfaces and copied
    // diagnostics. New views should consume `runRecords` instead.
    @Published var logLines: [String] = []
    @Published var isRunning = false
    @Published var isCancelling = false
    @Published var rebuildingChannels = false
    @Published var stats: [String: Int] = [:]
    @Published var toast: String?
    @Published var pendingConfirm: PendingConfirm?
    @Published var importPlan: ImportPlan?

    @Published var downloadMode = "all"
    @Published var downloadDays = 30
    @Published var steps: [PipelineStep] = [
        PipelineStep(id: "download", name: "下载文献", subtitle: "从 Europe PMC 按期刊/关键词抓取"),
        PipelineStep(id: "merge", name: "合并入库", subtitle: "解析并去重写入数据库"),
        PipelineStep(id: "translate", name: "翻译标题与摘要", subtitle: "调用 AI 批量翻译标题与摘要"),
        PipelineStep(id: "classify", name: "智能分类", subtitle: "调用 AI 按问题初筛"),
    ]

    // Pipeline coordination is module-internal so the focused pipeline extension
    // can share it without exposing an API outside this executable target.
    var cancelToken: CancelToken?
    var currentStepID: String?
    var stepStartTime: Date?
    var subStartTimes: [String: Date] = [:]
    var subEndTimes: [String: Date] = [:]

    // 统计页只缓存本次应用运行期间的数据：项目数据或配置发生写入后会立即失效，
    // 不落盘，避免跨次启动显示旧结论。以下协调状态由 Statistics.swift 在主线程维护。
    var statsBundleCache: StatsBundle?
    var statsCacheWorkspacePath: String?
    var statsCacheGeneration = 0
    var statsBasicLoading = false
    var statsBasicCompletions: [(StatsBundle?) -> Void] = []
    var statsInsightLoading = false
    var statsInsightRequests: [StatsInsightRequest] = []

    init() {
        if let ws = try? WorkspaceStore.resolve() {
            openExisting(ws)
        }
    }

    var needsSetup: Bool { config.activeProfile?.isComplete != true }
}

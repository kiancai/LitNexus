import Foundation

// Value types shared by the focused AppState extensions.

enum Route { case chooser, setup, main }

enum Page: String, CaseIterable {
    case run = "运行"
    case data = "数据"
    case stats = "统计"
    case settings = "配置"

    /// 侧栏与页面标题共享同一套语义图标，避免同一页面出现两种视觉语言。
    var symbol: String {
        switch self {
        case .run: return "play.circle"
        case .data: return "cylinder.split.1x2"
        case .stats: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}

// ── 统计页数据 ──────────────────────────────────────────────────────────────

struct StatDimension: Identifiable, Equatable { var id: String { column }; let label: String; let column: String }

/// 统计页的按需洞察。
///
/// 基础统计（总览、年代、来源、期刊）始终随 `StatsBundle` 一起读取；这些项目
/// 往往是用户刚进入页面就会看到的。其余洞察可能要扫描大量文章或读取完整文本，
/// 因此仅在对应卡片展开时加载。
enum StatsInsight: String, CaseIterable, Hashable {
    case promptDistribution
    case promptAgreement
    case keywordTerms
    case journalObservations
}

/// 等待按需洞察完成的调用。保存在 AppState 内，避免多个展开卡片重复打开数据库。
struct StatsInsightRequest {
    let insights: Set<StatsInsight>
    let completion: (StatsBundle?) -> Void
}

// 某问题 AI 答案与人工裁决的一致性 + 分歧示例。
struct QAgreement {
    let question: Question
    let tp: Int, fp: Int, fn: Int, tn: Int          // tp:AI是/纳入 fp:AI是/排除 fn:AI否/纳入 tn:AI否/排除
    let falseNeg: [(title: String, reason: String)] // AI 漏判：AI 判否、你纳入
    let falsePos: [(title: String, reason: String)] // AI 误纳：AI 判是、你排除
    var reviewed: Int { tp + fp + fn + tn }
    var agreeRate: Double { reviewed > 0 ? Double(tp + tn) / Double(reviewed) : 0 }
}

struct StatsBundle {
    /// 已加载的按需洞察。空集合意味着当前 bundle 只有基础统计。
    private(set) var loadedInsights: Set<StatsInsight> = []
    var overview: [String: Int] = [:]
    var dimensions: [StatDimension] = []                                       // 年代图可选维度
    var yearRaw: [String: [(year: Int, value: String?, count: Int)]] = [:]     // column -> 原始分组
    var sources: [(value: String?, count: Int)] = []

    // ── 按需洞察（只在 `loadedInsights` 含对应值时可被视为完整） ──────────────
    var questions: [(question: Question, yes: Int, no: Int, na: Int, pending: Int)] = []
    /// 全部期刊聚合。展示层决定筛选、搜索和排序，统计层不再只提供 Top N。
    var journals: [JournalStat] = []

    /// 旧统计视图的过渡入口。
    ///
    /// 新代码应读取 `journals`，以保证所有期刊均可访问。这个计算属性不触发额外查询，
    /// 仅避免旧视图和新统计数据切换期间出现编译断裂。
    @available(*, deprecated, message: "Use journals and let the presentation choose its own range.")
    var topJournals: [(value: String, count: Int)] {
        journals.prefix(10).map { (value: $0.journal, count: $0.total) }
    }
    var journalRank: [JournalStat] = []      // ① 入选率榜（已复筛达阈值，按入选率排序）
    var suggestAdd: [JournalStat] = []        // ② 建议加入期刊列表
    var suggestPrune: [JournalStat] = []      // ② 建议精简
    var agreements: [QAgreement] = []         // ④ AI vs 人工一致性
    /// 跨全部启用问题的人工/AI 对照：供「综合评判」和导出使用。
    var promptCombinedEvaluation = PromptCombinedEvaluation()
    var keywordTerms: [(term: String, total: Int, included: Int, uniqueIncluded: Int)] = []  // ③ 检索词产出
    var channelMapBuilt = false               // article_terms 是否已建立

    func hasLoaded(_ insight: StatsInsight) -> Bool { loadedInsights.contains(insight) }

    mutating func markLoaded(_ insights: Set<StatsInsight>) {
        loadedInsights.formUnion(insights)
    }
}

// ── 流水线进度 ──────────────────────────────────────────────────────────────

enum StepStatus { case idle, running, success, failed }

struct SubProgress: Identifiable, Equatable {
    let key: String
    var id: String { key }
    var label: String
    var current: Int
    var total: Int
    var item: String
    var eta: String = ""
    var startedAt: Date? = nil      // 正计时起点
    var endedAt: Date? = nil        // 完成时刻（冻结已用时间，避免跑完后继续走）
    var etaDeadline: Date? = nil    // 倒计时终点（= 现在 + 预估剩余）
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
    var warning: String = ""        // 非致命告警（如部分检索式不完整），琥珀色显示
    var startedAt: Date? = nil      // 正计时起点
    var etaDeadline: Date? = nil    // 倒计时终点（= 现在 + 预估剩余）
    var subs: [SubProgress] = []
    var progress: Double? { total > 0 ? min(1, Double(current) / Double(total)) : nil }
}

/// A presentation-ready entry in the current run's record.
///
/// The event remains language-neutral; views select a localized description from
/// its stable code and values, and only reveal `technicalText` in detail mode.
struct RunRecord: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let stepID: String?
    let event: PipelineEvent

    init(id: UUID = UUID(), timestamp: Date = Date(), stepID: String?, event: PipelineEvent) {
        self.id = id
        self.timestamp = timestamp
        self.stepID = stepID
        self.event = event
    }
}

// 线程安全的中止令牌：UI 线程置位，引擎后台线程在安全检查点读取。
final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

// 把引擎进度上报转发到界面（事件 + 进度 + 子进度，调用方负责回主线程更新）。
final class UIReporter: ProgressReporter {
    private let onEvent: (PipelineEvent) -> Void
    private let onProgress: (_ completed: Int, _ total: Int) -> Void
    private let onSub: (_ key: String, _ label: String, _ current: Int, _ total: Int, _ item: String) -> Void
    private let onWarn: (String) -> Void
    private let token: CancelToken
    private let progressLock = NSLock()
    private var total = 0
    private var completed = 0

    init(onEvent: @escaping (PipelineEvent) -> Void,
         onProgress: @escaping (Int, Int) -> Void,
         onSub: @escaping (String, String, Int, Int, String) -> Void,
         onWarn: @escaping (String) -> Void,
         token: CancelToken) {
        self.onEvent = onEvent
        self.onProgress = onProgress
        self.onSub = onSub
        self.onWarn = onWarn
        self.token = token
    }

    func report(_ event: PipelineEvent) { onEvent(event) }

    func addTask(_ description: String, total: Int?) -> Int {
        progressLock.lock()
        self.total = total ?? 0
        self.completed = 0
        let progressTotal = self.total
        progressLock.unlock()
        report(.taskStarted(total: total, technicalDescription: description))
        onProgress(0, progressTotal)
        return 0
    }

    func update(_ taskID: Int, advance: Int) {
        progressLock.lock()
        completed += advance
        let progressCompleted = completed
        let progressTotal = total
        progressLock.unlock()
        onProgress(progressCompleted, progressTotal)
    }

    func complete(_ taskID: Int) {
        progressLock.lock()
        let progressCompleted = completed
        let progressTotal = total
        progressLock.unlock()
        report(.taskCompleted(completed: progressCompleted, total: progressTotal))
    }

    func log(_ message: String) { report(.legacyLog(message)) }

    func subProgress(key: String, label: String, current: Int, total: Int, item: String) {
        onSub(key, label, current, total, item)
    }

    func warn(_ message: String) {
        report(.legacyWarning(message))
        onWarn(message)
    }

    func isCancelled() -> Bool { token.isCancelled }
}

// ── 导入数据库时的问题列对齐 ────────────────────────────────────────────────

enum QMapAction: Hashable { case map(String); case createNew; case skip }

struct ImportQRow: Identifiable {
    let id = UUID()
    let srcId: String
    let srcNickname: String?
    let srcText: String?
    var action: QMapAction
    var label: String {
        if let n = srcNickname, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        return srcId
    }
}

struct ImportPlan: Identifiable {
    let id = UUID()
    let source: URL
    let strategy: Database.ImportStrategy
    let total: Int
    var rows: [ImportQRow]
}

// 运行 AI 步骤前的二次确认请求。
struct PendingConfirm: Identifiable {
    let id = UUID()
    let stepID: String
    let title: String
    let message: String
    let onResult: (_ approved: Bool, _ remember: Bool) -> Void
}

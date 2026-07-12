import Foundation

/// A language-neutral event emitted while a pipeline is running.
///
/// `code` and `values` are the presentation contract.  UI layers can localize
/// them without depending on the engine's current language.  `technicalText`
/// is deliberately optional: it preserves legacy diagnostics until each engine
/// call site is migrated to structured events.
enum PipelineEventCategory: String, Equatable, Sendable {
    case lifecycle
    case progress
    case technical
}

enum PipelineEventLevel: String, Equatable, Sendable {
    case info
    case warning
    case error
}

struct PipelineEvent: Equatable, Sendable {
    let code: String
    let category: PipelineEventCategory
    let level: PipelineEventLevel
    let values: [String: String]
    let technicalText: String?

    init(code: String, category: PipelineEventCategory, level: PipelineEventLevel = .info,
         values: [String: String] = [:], technicalText: String? = nil) {
        self.code = code
        self.category = category
        self.level = level
        self.values = values
        self.technicalText = technicalText
    }

    static func legacyLog(_ text: String) -> PipelineEvent {
        PipelineEvent(code: "engine.legacy.log", category: .technical, technicalText: text)
    }

    static func legacyWarning(_ text: String) -> PipelineEvent {
        PipelineEvent(code: "engine.legacy.warning", category: .technical, level: .warning,
                      technicalText: text)
    }

    static func taskStarted(total: Int?, technicalDescription: String) -> PipelineEvent {
        var values = ["task_id": "0"]
        if let total { values["total"] = String(total) }
        return PipelineEvent(code: "progress.task.started", category: .progress,
                             values: values, technicalText: technicalDescription)
    }

    static func taskCompleted(completed: Int, total: Int) -> PipelineEvent {
        PipelineEvent(code: "progress.task.completed", category: .progress,
                      values: ["task_id": "0", "completed": String(completed), "total": String(total)])
    }

    static func stepStarted(stepID: String) -> PipelineEvent {
        PipelineEvent(code: "pipeline.step.started", category: .lifecycle,
                      values: ["step_id": stepID])
    }

    static func stepSucceeded(stepID: String, duration: TimeInterval?, technicalResult: String?) -> PipelineEvent {
        var values = ["step_id": stepID]
        if let duration { values["duration_milliseconds"] = String(Int((duration * 1_000).rounded())) }
        return PipelineEvent(code: "pipeline.step.succeeded", category: .lifecycle,
                             values: values, technicalText: technicalResult)
    }

    static func stepFailed(stepID: String, error: Error) -> PipelineEvent {
        PipelineEvent(code: "pipeline.step.failed", category: .lifecycle, level: .error,
                      values: ["step_id": stepID, "error_type": String(reflecting: type(of: error))],
                      technicalText: error.localizedDescription)
    }

    static func stepCancelled(stepID: String, reason: String) -> PipelineEvent {
        PipelineEvent(code: "pipeline.step.cancelled", category: .lifecycle,
                      values: ["step_id": stepID, "reason": reason])
    }

    static func cancellationRequested(stepID: String?) -> PipelineEvent {
        var values = ["reason": "user_requested"]
        if let stepID { values["step_id"] = stepID }
        return PipelineEvent(code: "pipeline.cancellation.requested", category: .lifecycle,
                             level: .warning, values: values)
    }
}

// 引擎与界面共用的进度上报协议。
// 界面层实现它即可把下载/翻译/分类进度显示到日志面板；引擎函数接受可选 reporter。

protocol ProgressReporter: AnyObject {
    func addTask(_ description: String, total: Int?) -> Int
    func update(_ taskID: Int, advance: Int)
    func complete(_ taskID: Int)
    /// Preferred future-facing event API. Existing engine emitters can keep
    /// using `log` / `warn`; both are bridged to structured technical events.
    func report(_ event: PipelineEvent)
    func log(_ message: String)
    /// 细粒度子进度（如下载时按「期刊 / 关键词」分别推进，并显示当前正在处理的名称）。
    /// key 唯一标识一个子任务；engine 不关心 UI 如何展示。默认无操作。
    func subProgress(key: String, label: String, current: Int, total: Int, item: String)
    /// 非致命告警（如某检索式重试失败、结果不完整）。界面可在当前步骤上以醒目色展示。
    func warn(_ message: String)
    /// 是否已请求中止。引擎在安全检查点（每页/每文件/每批次之间）查询，为真则尽快干净停止。
    func isCancelled() -> Bool
}

extension ProgressReporter {
    func update(_ taskID: Int, advance: Int = 1) { update(taskID, advance: advance) }
    func report(_ event: PipelineEvent) {}
    func subProgress(key: String, label: String, current: Int, total: Int, item: String) {}
    func warn(_ message: String) { log(message) }  // 默认退化为普通日志
    func isCancelled() -> Bool { false }
}

/// 用户主动中止流水线时，引擎在安全检查点抛出它（区别于真正的错误）。
struct PipelineCancelled: Error {}

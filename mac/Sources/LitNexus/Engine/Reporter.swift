import Foundation

// 进度上报协议，对应 Python 参考里 reporter 适配器（add_task/update/complete/log）。
// 界面层实现它即可把下载/翻译/分类进度显示到日志面板；引擎函数接受可选 reporter。

protocol ProgressReporter: AnyObject {
    func addTask(_ description: String, total: Int?) -> Int
    func update(_ taskID: Int, advance: Int)
    func complete(_ taskID: Int)
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
    func subProgress(key: String, label: String, current: Int, total: Int, item: String) {}
    func warn(_ message: String) { log(message) }  // 默认退化为普通日志
    func isCancelled() -> Bool { false }
}

/// 用户主动中止流水线时，引擎在安全检查点抛出它（区别于真正的错误）。
struct PipelineCancelled: Error {}

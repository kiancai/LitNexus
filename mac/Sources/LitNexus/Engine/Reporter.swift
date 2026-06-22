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
}

extension ProgressReporter {
    func update(_ taskID: Int, advance: Int = 1) { update(taskID, advance: advance) }
    func subProgress(key: String, label: String, current: Int, total: Int, item: String) {}
}

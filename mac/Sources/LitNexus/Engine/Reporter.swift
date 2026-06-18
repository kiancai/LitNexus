import Foundation

// 进度上报协议，对应 Python 参考里 reporter 适配器（add_task/update/complete/log）。
// 界面层实现它即可把下载/翻译/分类进度显示到日志面板；引擎函数接受可选 reporter。

protocol ProgressReporter: AnyObject {
    func addTask(_ description: String, total: Int?) -> Int
    func update(_ taskID: Int, advance: Int)
    func complete(_ taskID: Int)
    func log(_ message: String)
}

extension ProgressReporter {
    func update(_ taskID: Int, advance: Int = 1) { update(taskID, advance: advance) }
}

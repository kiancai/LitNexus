import Foundation

// 实时联网验证 EPMC 下载 → 合并端到端（打真实 API，不需要 key）。
// 运行：swift run LitNexus epmctest

enum SelfTestLive {
    final class PrintReporter: ProgressReporter {
        func addTask(_ description: String, total: Int?) -> Int { print("  · \(description)（共 \(total ?? -1)）"); return 0 }
        func update(_ taskID: Int, advance: Int) {}
        func complete(_ taskID: Int) {}
        func log(_ message: String) { print(message) }
    }

    static func run() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("litnexus_epmc_\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        print("EPMC 实时验证 @ \(tmp.path)")
        do {
            let ws = try WorkspaceStore.create(tmp)
            // 用一个小检索式 + 短时间窗，控制返回量
            try "Bioinformatics\n".write(to: ws.journalsFile, atomically: true, encoding: .utf8)
            var cfg = try ConfigStore.load(ws.configPath)
            cfg.download.pageSize = 50
            cfg.download.days = 3

            let reporter = PrintReporter()
            let files = try EPMCClient.runDownload(config: cfg, workspace: ws, mode: "journals", days: 3, reporter: reporter)
            print("生成 JSONL：\(files.map(\.lastPathComponent))")

            let db = try Database(path: ws.dbPath, config: cfg)
            let mr = try Pipeline.mergeJSONL(db: db, downloadsDir: ws.downloadsDir, reporter: reporter)
            let total = try db.stats(questions: cfg.classify.questions)["total"] ?? 0
            print("\n合并：插入 \(mr.inserted)，重复 \(mr.skipped)，错误 \(mr.errors)；库内 total=\(total)")
            print(total > 0 ? "✓ EPMC 端到端通过" : "✗ 未取到任何文章（可能近 3 天该刊无新文，换条件再试）")
            exit(total > 0 ? 0 : 1)
        } catch {
            print("✗ 异常：\(error)")
            exit(1)
        }
    }
}

import Foundation

// 引擎自检：在临时目录跑一遍工作区/配置/数据库逻辑，验证移植正确。
// 运行：swift run LitNexus selftest

enum SelfTest {
    static func run() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("litnexus_selftest_\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        print("LitNexus 引擎自检 @ \(tmp.path)")
        do {
            // 工作区创建 + 模板
            let ws = try WorkspaceStore.create(tmp)
            check("工作区已初始化", ws.isInitialized)
            check("journals 模板含示例", (try? String(contentsOf: ws.journalsFile)).map { $0.contains("Nature") } ?? false)
            check("keywords 文件被识别", ws.keywordsFiles.contains { $0.lastPathComponent == "keywords.txt" })

            // 配置默认值 + 往返
            var cfg = try ConfigStore.load(ws.configPath)
            check("默认两个问题", cfg.classify.questions.map(\.id) == ["q1", "q2"])
            check("AI 无默认值", cfg.ai.baseURL.isEmpty && cfg.ai.model.isEmpty)
            check("默认标注列 include/tags", cfg.schema.customColumns == ["include", "tags"])

            cfg.ai.baseURL = "https://example.com/v1"
            cfg.ai.model = "test-model"
            cfg.download.days = 7
            try ConfigStore.save(cfg, to: ws.configPath)
            let reloaded = try ConfigStore.load(ws.configPath)
            check("配置往返：base_url", reloaded.ai.baseURL == "https://example.com/v1")
            check("配置往返：days", reloaded.download.days == 7)
            check("配置往返：问题保留", reloaded.classify.questions.map(\.id) == ["q1", "q2"])

            // 数据库：建库 + 动态列 + 去重插入 + 统计
            let dbv = try Database(path: ws.dbPath, config: cfg)
            let dynCols = Set(try dbv.existingColumns())
            check("动态列 q1_ans 已建", dynCols.contains("q1_ans"))
            check("标注列 include 已建", dynCols.contains("include"))

            let art1: [String: DBValue] = [
                "epmc_id": .text("E1"), "pmid": .text("1"), "doi": .text("d1"),
                "title": .text("Title One"), "pub_year": .int(2026),
            ]
            let art2dup: [String: DBValue] = [
                "epmc_id": .text("E2"), "pmid": .text("1"), "doi": .text("d2"),
                "title": .text("Title Two"), "pub_year": .int(2026),
            ]
            let r1 = try dbv.insertArticles([art1])
            check("首次插入 (1,0)", r1 == (1, 0))
            let r2 = try dbv.insertArticles([art2dup])
            check("同 pmid 去重 (0,1)", r2 == (0, 1))

            let s = try dbv.stats(questions: cfg.classify.questions)
            check("统计 total=1", s["total"] == 1)
            check("统计 pending_translation=1", s["pending_translation"] == 1)
            check("统计 pending_q1=1", s["pending_q1"] == 1)

            // 翻译往返
            try dbv.updateTranslations([("E1", "标题一")])
            check("翻译后 pending_translation=0", try dbv.stats(questions: cfg.classify.questions)["pending_translation"] == 0)
        } catch {
            failed += 1
            print("  ✗ 异常：\(error)")
        }

        print("\n结果：\(passed) 通过，\(failed) 失败")
        exit(failed == 0 ? 0 : 1)
    }
}

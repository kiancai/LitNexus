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
        func cleanup() { try? FileManager.default.removeItem(at: tmp) }

        print("LitNexus 引擎自检 @ \(tmp.path)")
        do {
            // 工作区创建 + 模板（makeActive: false：不污染用户的活动工作区指针）
            let ws = try WorkspaceStore.create(tmp, makeActive: false)
            check("工作区已初始化", ws.isInitialized)
            check("journals 模板含示例", (try? String(contentsOf: ws.journalsFile)).map { $0.contains("Nature") } ?? false)
            check("keywords 文件被识别", ws.keywordsFiles.contains { $0.lastPathComponent == "keywords.txt" })

            // 配置默认值 + 往返
            var cfg = try ConfigStore.load(ws.configPath)
            check("默认两个问题", cfg.classify.questions.map(\.id) == ["q1", "q2"])
            check("AI 无默认值", cfg.ai.baseURL.isEmpty && cfg.ai.model.isEmpty)
            check("默认标注列 include/tags", cfg.schema.customColumns == ["include", "tags"])

            let prof = AIProfile(name: "test", baseURL: "https://example.com/v1", model: "test-model")
            cfg.aiProfiles = [prof]
            cfg.activeAIID = prof.id
            cfg.download.days = 7
            try ConfigStore.save(cfg, to: ws.configPath)
            let reloaded = try ConfigStore.load(ws.configPath)
            check("配置往返：base_url", reloaded.ai.baseURL == "https://example.com/v1")
            check("配置往返：days", reloaded.download.days == 7)
            check("配置往返：问题保留", reloaded.classify.questions.map(\.id) == ["q1", "q2"])
            check("配置往返：昵称保留", reloaded.classify.questions.first?.nickname == "生物医学领域")
            check("默认翻译摘要为开", reloaded.translate.translateAbstract)

            // 问题模型：classify/export 开关 + 永不复用 id
            var cfg2 = reloaded
            cfg2.classify.questions[1].classify = false
            cfg2.classify.questions[1].export = false
            try ConfigStore.save(cfg2, to: ws.configPath)
            let rel2 = try ConfigStore.load(ws.configPath)
            check("配置往返：classify 开关", rel2.classify.questions[1].classify == false)
            check("配置往返：export 开关", rel2.classify.questions[1].export == false)
            check("下一个问题 id 永不复用", rel2.classify.nextQuestionID() == "q3")

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

            // EPMC JSON → 字段映射
            let rawArticle: [String: Any] = [
                "id": "E9", "pmid": "99", "doi": "d99", "source": "MED",
                "title": "Sample Title", "abstractText": "Abs", "pubYear": "2025",
                "authorString": "Doe J",
                "journalInfo": ["journal": ["title": "Nature"]],
                "firstPublicationDate": "2025-01-01",
                "keywordList": ["keyword": ["a", "b"]],
            ]
            let p = ArticleIO.parseArticle(rawArticle)
            check("parseArticle epmc_id", p["epmc_id"]?.stringValue == "E9")
            check("parseArticle journal_title", p["journal_title"]?.stringValue == "Nature")
            check("parseArticle pub_year", p["pub_year"]?.intValue == 2025)
            check("parseArticle journal_json 非空", p["journal_info_json"]?.stringValue != nil)

            // JSONL 合并（一条重复 pmid、一条缺 id）
            let jsonl = [
                "{\"id\":\"M1\",\"pmid\":\"500\",\"title\":\"T M1\",\"pubYear\":\"2026\"}",
                "{\"id\":\"M2\",\"pmid\":\"500\",\"title\":\"T M2\",\"pubYear\":\"2026\"}",
                "{\"title\":\"no id\"}",
            ].joined(separator: "\n")
            try jsonl.write(to: ws.downloadsDir.appendingPathComponent("test.jsonl"), atomically: true, encoding: .utf8)
            let mr = try Pipeline.mergeJSONL(db: dbv, downloadsDir: ws.downloadsDir, reporter: nil)
            check("merge inserted=1", mr.inserted == 1)
            check("merge skipped=1（dup pmid）", mr.skipped == 1)
            check("merge errors=1（缺 id）", mr.errors == 1)
            check("已合并文件移入 _merged",
                  FileManager.default.fileExists(atPath: ws.downloadsDir.appendingPathComponent("_merged/test.jsonl").path))
            let mr2 = try Pipeline.mergeJSONL(db: dbv, downloadsDir: ws.downloadsDir, reporter: nil)
            check("二次合并无新文件 files=0", mr2.files == 0)

            // CSV 导出 + 排除列 + BOM
            let csvOut = ws.exportsDir.appendingPathComponent("out.csv")
            let n = try Pipeline.exportArticles(db: dbv, config: cfg, filterMode: "all", output: csvOut)
            check("export 行数=total(2)", n == 2)
            let csvText = try String(contentsOf: csvOut, encoding: .utf8)
            let csvBytes = try Data(contentsOf: csvOut)
            check("CSV 带 utf-8-sig BOM", csvBytes.prefix(3).elementsEqual([0xEF, 0xBB, 0xBF]))
            let (hdr, _) = CSV.parseWithHeader(csvText)
            check("CSV 表头含 epmc_id", hdr.contains("epmc_id"))
            check("CSV 排除 journal_info_json", !hdr.contains("journal_info_json"))
            check("CSV 表头用问题昵称", hdr.contains("生物医学领域 · 答案"))

            // 导出开关=关 → 该问题两列被排除
            var cfgNoExport = cfg
            cfgNoExport.classify.questions[0].export = false
            let csvOut2 = ws.exportsDir.appendingPathComponent("out2.csv")
            _ = try Pipeline.exportArticles(db: dbv, config: cfgNoExport, filterMode: "all", output: csvOut2)
            let (hdr2, _) = CSV.parseWithHeader(try String(contentsOf: csvOut2, encoding: .utf8))
            check("导出关闭的问题列被排除", !hdr2.contains("生物医学领域 · 答案"))

            // 永久删除问题：DROP 掉 q2_ans/q2_rea
            try dbv.dropQuestionColumns("q2")
            let afterDrop = Set(try dbv.existingColumns())
            check("永久删除后 q2_ans 已移除", !afterDrop.contains("q2_ans") && !afterDrop.contains("q2_rea"))
            check("q1_ans 仍在", afterDrop.contains("q1_ans"))

            // 整库导入（从另一份 .db 合并，含大小写不同的列名）
            let srcDBPath = tmp.appendingPathComponent("src_import.db")
            let srcDB = try Database(path: srcDBPath, config: cfg)
            try srcDB.exec("UPDATE articles SET title='x' WHERE 0")  // 确保表存在
            _ = try srcDB.insertArticles([[
                "epmc_id": .text("IMP1"), "pmid": .text("9001"), "doi": .text("dimp1"),
                "title": .text("Imported"), "pub_year": .int(2024),
            ]])
            let beforeImport = try dbv.stats(questions: cfg.classify.questions)["total"] ?? 0
            let (ins, _, srcTotal) = try dbv.importFromDatabase(srcDBPath)
            check("整库导入新增 1", ins == 1)
            check("整库导入源库计数=1", srcTotal == 1)
            let afterImport = try dbv.stats(questions: cfg.classify.questions)["total"] ?? 0
            check("整库导入后 total +1", afterImport == beforeImport + 1)

            // 复筛 CSV 导回（include 小写归一）
            let reviewCSV = "\u{FEFF}epmc_id,include,tags\r\nE1,YES,important\r\nM1,no,\r\n"
            let revPath = ws.exportsDir.appendingPathComponent("review.csv")
            try reviewCSV.write(to: revPath, atomically: true, encoding: .utf8)
            let (upd, _, tot) = try ArticleIO.importReviewedCSV(dbv, csvPath: revPath, annotationColumns: cfg.schema.customColumns)
            check("import updated=2", upd == 2)
            check("import total=2", tot == 2)
            let rs = try dbv.stats(questions: cfg.classify.questions)
            check("import include 归一 reviewed_yes=1", rs["reviewed_yes"] == 1)
            check("import reviewed_no=1", rs["reviewed_no"] == 1)

            // AI 响应解析（离线）
            let tb = AIClient.parseBatchResponse("[{\"id\":1,\"title_zh\":\"标题一\"},{\"id\":2,\"title_zh\":\"标题二\"}]")
            check("parseBatchResponse 直接", tb[1] == "标题一" && tb[2] == "标题二")
            let tb2 = AIClient.parseBatchResponse("```json\n[{\"id\":1,\"title_zh\":\"X\"}]\n```")
            check("parseBatchResponse 代码块", tb2[1] == "X")
            let cls = AIClient.parseClassifyResponse(
                "{\"q1\":{\"answer\":\"是\",\"reason\":\"r1\"},\"q2\":{\"answer\":\"否\",\"reason\":\"r2\"}}",
                questions: cfg.classify.questions)
            check("parseClassifyResponse q1=是", cls["q1"]?.answer == "是")
            check("parseClassifyResponse q2 reason", cls["q2"]?.reason == "r2")
        } catch {
            failed += 1
            print("  ✗ 异常：\(error)")
        }

        cleanup()
        print("\n结果：\(passed) 通过，\(failed) 失败")
        exit(failed == 0 ? 0 : 1)
    }
}

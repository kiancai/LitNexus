import Foundation

// Offline regression checks for engine behavior.

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

            // 配置默认值 + 往返
            var cfg = try ConfigStore.load(ws.configPath)
            check("默认期刊（toml）含示例", cfg.download.journals.contains("Nature"))
            check("默认关键词（toml）非空", cfg.download.keywords.contains { $0.contains("microbiome") })
            check("默认两个问题", cfg.classify.questions.map(\.id) == ["q1", "q2"])
            check("AI 无默认值", cfg.ai.baseURL.isEmpty && cfg.ai.model.isEmpty)
            check("默认标注列 include/tags", cfg.schema.customColumns == ["include", "tags"])
            check("默认项目主题色为默认 teal", cfg.theme.accentHue == nil)

            let prof = AIProfile(name: "test", baseURL: "https://example.com/v1", model: "test-model")
            cfg.aiProfiles = [prof]
            cfg.activeAIID = prof.id
            cfg.download.days = 7
            cfg.download.journals = ["Nature", "# 注释", "Cell"]
            cfg.download.keywords = ["(a OR b) AND \"c d\""]
            cfg.theme.accentHue = 0.71
            try ConfigStore.save(cfg, to: ws.configPath)
            let reloaded = try ConfigStore.load(ws.configPath)
            check("配置往返：base_url", reloaded.ai.baseURL == "https://example.com/v1")
            check("配置往返：days", reloaded.download.days == 7)
            check("配置往返：journals 数组", reloaded.download.journals == ["Nature", "# 注释", "Cell"])
            check("配置往返：keywords 含引号检索式", reloaded.download.keywords == ["(a OR b) AND \"c d\""])
            check("配置往返：项目强调色", reloaded.theme.accentHue == 0.71)
            check("检索式过滤注释/空行", EPMCClient.filterQueries(reloaded.download.journals) == ["Nature", "Cell"])
            check("配置往返：问题保留", reloaded.classify.questions.map(\.id) == ["q1", "q2"])
            check("配置往返：昵称保留", reloaded.classify.questions.first?.nickname == "生物医学领域")
            check("默认翻译摘要为开", reloaded.translate.translateAbstract)

            // 问题模型：classify/export 开关 + 永不复用 id
            var cfg2 = reloaded
            cfg2.classify.questions[1].classify = false
            cfg2.classify.questions[1].export = false
            cfg2.classify.questions[1].classifyAfterRowID = 42
            try ConfigStore.save(cfg2, to: ws.configPath)
            let rel2 = try ConfigStore.load(ws.configPath)
            check("配置往返：classify 开关", rel2.classify.questions[1].classify == false)
            check("配置往返：export 开关", rel2.classify.questions[1].export == false)
            check("配置往返：问题未来范围", rel2.classify.questions[1].classifyAfterRowID == 42)
            check("下一个问题 id 永不复用", rel2.classify.nextQuestionID() == "q3")

            // 问题生命周期：归档不篡改原 classify 偏好；高水位跨删除、跨保存都不回退。
            var lifecycle = reloaded
            lifecycle.classify.questions[0].archived = true
            check("归档问题保留原 AI 开关", lifecycle.classify.questions[0].classify)
            check("归档问题不参与未来分类", !lifecycle.classify.questions[0].isActiveForClassification)
            lifecycle.classify.questions[0].archived = false
            check("恢复归档后沿用原 AI 开关", lifecycle.classify.questions[0].isActiveForClassification)
            let allocatedQ3 = lifecycle.classify.allocateQuestionID()
            lifecycle.classify.questions.append(Question(id: allocatedQ3, text: "临时问题"))
            lifecycle.classify.questions.removeAll { $0.id == allocatedQ3 }
            let allocatedQ4 = lifecycle.classify.allocateQuestionID()
            check("永久删除后问题 id 不复用", allocatedQ3 == "q3" && allocatedQ4 == "q4")
            lifecycle.classify.questions[0].archived = true
            let lifecyclePath = tmp.appendingPathComponent("lifecycle.toml")
            try ConfigStore.save(lifecycle, to: lifecyclePath)
            let lifecycleReloaded = try ConfigStore.load(lifecyclePath)
            check("问题高水位持久化", lifecycleReloaded.classify.nextQuestionID() == "q5")
            check("配置往返：归档状态", lifecycleReloaded.classify.questions[0].archived == true)

            // 兼容没有 archived / next_question_number 的旧 TOML：按现存最大 q<N> 推断下一编号。
            var legacyCfg = AppConfig()
            legacyCfg.classify.questions = [Question(id: "q9", nickname: "旧问题", text: "legacy")]
            legacyCfg.classify.nextQuestionNumber = 10
            let legacyPath = tmp.appendingPathComponent("legacy_questions.toml")
            let legacyTOML = ConfigStore.serialize(legacyCfg)
                .components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("next_question_number") && !$0.hasPrefix("archived") }
                .joined(separator: "\n")
            try legacyTOML.write(to: legacyPath, atomically: true, encoding: .utf8)
            let legacyReloaded = try ConfigStore.load(legacyPath)
            check("旧 TOML 默认未归档", legacyReloaded.classify.questions.first?.archived == false)
            check("旧 TOML 推断问题高水位", legacyReloaded.classify.nextQuestionID() == "q10")

            // 数据库：建库 + 动态列 + 去重插入 + 统计
            let dbv = try Database(path: ws.dbPath, config: cfg)
            let dynCols = Set(try dbv.existingColumns())
            check("动态列 q1_ans 已建", dynCols.contains("q1_ans"))
            check("标注列 include 已建", dynCols.contains("include"))

            // 数据库自描述元数据：归档状态随 .db 保存；永久删除前必须能生成独立备份。
            var archivedCfg = cfg
            archivedCfg.classify.questions[0].archived = true
            let archiveDB = try Database(path: tmp.appendingPathComponent("archived_question.db"), config: archivedCfg)
            let archiveMeta = try archiveDB.query(
                "SELECT archived, classify_enabled FROM litnexus_questions WHERE id = 'q1'").rows.first
            check("问题元数据记录 archived", archiveMeta?["archived"]?.intValue == 1)
            check("问题元数据保留原 classify", archiveMeta?["classify_enabled"]?.intValue == 1)
            let questionBackup = try archiveDB.backupBeforeQuestionDeletion("q2")
            check("永久删除前创建独立备份", FileManager.default.fileExists(atPath: questionBackup.path))
            try archiveDB.dropQuestionColumns("q2")
            let archiveColsAfterDrop = Set(try archiveDB.existingColumns())
            let deletedMeta = try archiveDB.query("SELECT id FROM litnexus_questions WHERE id = 'q2'").rows
            check("永久删除移除问题列", !archiveColsAfterDrop.contains("q2_ans") && !archiveColsAfterDrop.contains("q2_rea"))
            check("永久删除移除问题元数据", deletedMeta.isEmpty)

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
            let regularBackup = try dbv.backup()
            check("常规备份为独立 SQLite 快照", FileManager.default.fileExists(atPath: regularBackup.path))

            // 新问题默认只面向创建后合并的文章：历史文章不应因为“新增问题”而在
            // 下一次普通分类中被悄悄补答；用户明确选择全历史后才会改变该边界。
            let scopePath = tmp.appendingPathComponent("question_scope.db")
            let futureFrontier: Int
            do {
                let before = try Database(path: scopePath, config: cfg)
                _ = try before.insertArticles([[
                    "epmc_id": .text("OLD-Q"), "title": .text("older article"), "pub_year": .int(2020),
                ]])
                futureFrontier = try before.currentArticleRowID()
            }
            let futureQuestion = Question(
                id: "q3", nickname: "新范围", text: "future only", classifyAfterRowID: futureFrontier)
            var scopedConfig = cfg
            scopedConfig.classify.questions.append(futureQuestion)
            let scopedDB = try Database(path: scopePath, config: scopedConfig)
            _ = try scopedDB.insertArticles([[
                "epmc_id": .text("NEW-Q"), "title": .text("newer article"), "pub_year": .int(2026),
            ]])
            let futurePending = try scopedDB.fetchPendingClassification([futureQuestion])
            check("新增问题默认不补答历史文章", futurePending.map(\.epmcID) == ["NEW-Q"])
            check("未来范围的待分类统计只计新文章", try scopedDB.stats(questions: [futureQuestion])["pending_q3"] == 1)
            check("未来范围的年代统计不混入历史空答案",
                  try scopedDB.yearDimension("q3_ans", afterRowID: futureFrontier).map(\.year) == [2026])

            let s = try dbv.stats(questions: cfg.classify.questions)
            check("统计 total=1", s["total"] == 1)
            check("统计 pending_translation=1", s["pending_translation"] == 1)
            check("统计 pending_q1=1", s["pending_q1"] == 1)

            // 翻译往返
            try dbv.updateTranslations([("E1", "标题一")])
            check("翻译后 pending_translation=0", try dbv.stats(questions: cfg.classify.questions)["pending_translation"] == 0)

            // 跨问题提示词评估：人工纳入但有问题判否、全部问题判是但人工排除。
            // 单独使用小库，避免改变后续通用导出行数断言。
            let evalDB = try Database(path: tmp.appendingPathComponent("prompt_evaluation.db"), config: cfg)
            _ = try evalDB.insertArticles([
                ["epmc_id": .text("EV1"), "title": .text("Human included, AI denied"), "pub_year": .int(2024)],
                ["epmc_id": .text("EV2"), "title": .text("All AI yes, human excluded"), "pub_year": .int(2025)],
                ["epmc_id": .text("EV3"), "title": .text("Not all AI yes"), "pub_year": .int(2026)],
            ])
            try evalDB.writeClassification([
                ("EV1", ["q1": (answer: "否", reason: "too strict"), "q2": (answer: "是", reason: "fits")]),
                ("EV2", ["q1": (answer: "是", reason: "fits q1"), "q2": (answer: "是", reason: "fits q2")]),
                ("EV3", ["q1": (answer: "是", reason: "fits q1"), "q2": (answer: "否", reason: "misses q2")]),
            ])
            _ = try evalDB.run("UPDATE articles SET include = 'yes' WHERE epmc_id = 'EV1'")
            _ = try evalDB.run("UPDATE articles SET include = 'no' WHERE epmc_id IN ('EV2', 'EV3')")
            let combined = try evalDB.promptCombinedEvaluation(questions: cfg.classify.questions)
            check("综合评估：人工纳入且任一 AI 判否=1",
                  combined.humanIncludedButAnyAIDenied.map(\.epmcID) == ["EV1"])
            check("综合评估：全部 AI 判是且人工排除=1",
                  combined.humanExcludedButAllAIApproved.map(\.epmcID) == ["EV2"])
            check("综合评估：保留全部问题理由",
                  combined.humanExcludedButAllAIApproved.first?.answers.map(\.reason) == ["fits q1", "fits q2"])
            let promptCSV = ws.exportsDir.appendingPathComponent("all_ai_yes_human_excluded.csv")
            check("综合评估导出记录=1",
                  try evalDB.exportHumanExcludedButAllAIApproved(questions: cfg.classify.questions, to: promptCSV) == 1)
            let (promptHeader, promptRows) = CSV.parseWithHeader(try String(contentsOf: promptCSV, encoding: .utf8))
            check("综合评估 CSV 含每个问题答案", promptHeader.contains("生物医学领域 · AI 答案"))
            check("综合评估 CSV 仅导出 EV2", promptRows.map { $0["EPMC ID"] } == ["EV2"])

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

            // 归档问题保留数据库历史，但不能再出现在默认人工复筛导出中。
            var cfgArchivedExport = cfg
            cfgArchivedExport.classify.questions[0].archived = true
            let csvOutArchived = ws.exportsDir.appendingPathComponent("out_archived_question.csv")
            _ = try Pipeline.exportArticles(
                db: dbv, config: cfgArchivedExport, filterMode: "all", output: csvOutArchived)
            let (archivedHeader, _) = CSV.parseWithHeader(
                try String(contentsOf: csvOutArchived, encoding: .utf8))
            check("归档问题默认不导出", !archivedHeader.contains("生物医学领域 · 答案"))
            check("未归档问题仍正常导出", archivedHeader.contains("核心方向 · 答案"))

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

            // 导入对齐：源库自描述 + 把源 q1 映射到目标 q2
            let mapCfg = try ConfigStore.load(ws.configPath)
            let srcMPath = tmp.appendingPathComponent("srcM.db")
            let srcM = try Database(path: srcMPath, config: mapCfg)
            _ = try srcM.insertArticles([[
                "epmc_id": .text("MX"), "pmid": .text("7001"), "title": .text("t"), "pub_year": .int(2024)]])
            try srcM.writeClassification([("MX", ["q1": (answer: "是", reason: "r")])])
            let destM = try Database(path: tmp.appendingPathComponent("destM.db"), config: mapCfg)
            let inspM = try destM.inspectImport(srcMPath)
            check("inspect 源问题数=2", inspM.sourceQuestions.count == 2)
            check("inspect 源问题自描述文本", inspM.sourceQuestions.contains { $0.text?.contains("计算生物学") == true })
            let (insM, _, _) = try destM.importFromDatabase(
                srcMPath, strategy: .skipExisting,
                questionColumnPairs: [(dest: "q2_ans", src: "q1_ans"), (dest: "q2_rea", src: "q1_rea")])
            check("映射导入新增 1", insM == 1)
            let mrow = try destM.query("SELECT q1_ans, q2_ans FROM articles WHERE epmc_id='MX'").rows.first
            check("源 q1 答案落到目标 q2", mrow?["q2_ans"]?.stringValue == "是")
            check("目标 q1 未被写入", mrow?["q1_ans"]?.stringValue == nil)

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
            check("待复筛 reviewed_pending=1（IMP1 未复筛）", rs["reviewed_pending"] == 1)
            let incCSV = ws.exportsDir.appendingPathComponent("inc.csv")
            check("导出筛选 已纳入=1", try Pipeline.exportArticles(db: dbv, config: cfg, filterMode: "included", output: incCSV) == 1)
            let excCSV = ws.exportsDir.appendingPathComponent("exc.csv")
            check("导出筛选 已排除=1", try Pipeline.exportArticles(db: dbv, config: cfg, filterMode: "excluded", output: excCSV) == 1)

            // 人工复筛 CSV 的安全契约：只认 epmc_id + include/tags，先预检再确认写入。
            let safeReviewDB = try Database(path: tmp.appendingPathComponent("safe_review.db"), config: cfg)
            _ = try safeReviewDB.insertArticles([
                ["epmc_id": .text("R1"), "pmid": .text("PMID-R1"), "title": .text("original R1")],
                ["epmc_id": .text("R2"), "pmid": .text("PMID-R2"), "title": .text("original R2")],
                ["epmc_id": .text("R3"), "pmid": .text("PMID-R3"), "title": .text("original R3")],
            ])
            _ = try safeReviewDB.run("UPDATE articles SET include='yes', tags='kept' WHERE epmc_id='R2'")
            try safeReviewDB.writeClassification([("R1", ["q1": (answer: "是", reason: "original answer")])])

            let safeReviewCSV = CSV.write([
                ["epmc_id", "include", "tags", "title", "q1_ans"],
                [" R1 ", " YES ", "new tag", "changed title", "否"],
                ["R2", "no", "replace tag", "changed title", "否"],
                ["NOT-IN-DB", "yes", "unknown", "", ""],
                ["", "", "", "", ""],
            ])
            let safeReviewPath = ws.exportsDir.appendingPathComponent("review_safe.csv")
            try ("\u{FEFF}" + safeReviewCSV).write(to: safeReviewPath, atomically: true, encoding: .utf8)
            let safePlan = try ArticleIO.preflightReviewedCSV(safeReviewDB, csvPath: safeReviewPath)
            check("复筛预检：合法文件可确认", safePlan.canApply)
            check("复筛预检：只计划 R1 写回", safePlan.updates.map(\.epmcID) == ["R1"])
            check("复筛预检：YES 归一为 yes", safePlan.updates.first?.include == "yes")
            check("复筛预检：识别空行", safePlan.emptyRows == 1)
            check("复筛预检：未知 ID 仅警告", safePlan.unknownRows == 1 && safePlan.warningCount >= 2)
            check("复筛预检：默认保护已有 include/tags", safePlan.conflictedRows == 1)
            let safeResult = try ArticleIO.executeReviewedCSV(safeReviewDB, csvPath: safeReviewPath)
            check("复筛确认：仅更新计划行", safeResult.updatedRows == 1 && safeResult.updatedFields == 2)
            let safeRows = try safeReviewDB.query(
                "SELECT epmc_id, title, include, tags, q1_ans FROM articles WHERE epmc_id IN ('R1','R2') ORDER BY epmc_id").rows
            check("复筛只写 include/tags，不覆盖其他 CSV 列",
                  safeRows[0]["title"]?.stringValue == "original R1" && safeRows[0]["q1_ans"]?.stringValue == "是")
            check("复筛默认不覆盖已有标注",
                  safeRows[1]["include"]?.stringValue == "yes" && safeRows[1]["tags"]?.stringValue == "kept")

            let overwriteCSV = CSV.write([
                ["epmc_id", "include", "tags"],
                ["R2", "NO", "replacement"],
            ])
            let overwritePath = ws.exportsDir.appendingPathComponent("review_overwrite.csv")
            try overwriteCSV.write(to: overwritePath, atomically: true, encoding: .utf8)
            let overwritePlan = try ArticleIO.preflightReviewedCSV(safeReviewDB, csvPath: overwritePath, allowOverwrite: true)
            check("复筛预检：显式允许覆盖时生成写入计划", overwritePlan.updates.first?.epmcID == "R2")
            _ = try ArticleIO.executeReviewedCSV(safeReviewDB, csvPath: overwritePath, allowOverwrite: true)
            let overwritten = try safeReviewDB.query("SELECT include, tags FROM articles WHERE epmc_id='R2'").rows.first
            check("复筛确认：允许覆盖时更新已有标注",
                  overwritten?["include"]?.stringValue == "no" && overwritten?["tags"]?.stringValue == "replacement")

            let invalidReviewCSV = CSV.write([
                ["epmc_id", "include", "tags"],
                ["R3", "是", "should not write"],
            ])
            let invalidReviewPath = ws.exportsDir.appendingPathComponent("review_invalid.csv")
            try invalidReviewCSV.write(to: invalidReviewPath, atomically: true, encoding: .utf8)
            let invalidPlan = try ArticleIO.preflightReviewedCSV(safeReviewDB, csvPath: invalidReviewPath)
            check("复筛预检：非 yes/no 为阻断错误", !invalidPlan.canApply && invalidPlan.errorCount == 1)
            let beforeInvalid = try safeReviewDB.query("SELECT include, tags FROM articles WHERE epmc_id='R3'").rows.first
            do {
                _ = try ArticleIO.executeReviewedCSV(safeReviewDB, csvPath: invalidReviewPath)
                check("复筛确认：非法值不能写入", false)
            } catch {
                let afterInvalid = try safeReviewDB.query("SELECT include, tags FROM articles WHERE epmc_id='R3'").rows.first
                check("复筛确认：非法值不能写入", afterInvalid?["include"]?.stringValue == beforeInvalid?["include"]?.stringValue && afterInvalid?["tags"]?.stringValue == beforeInvalid?["tags"]?.stringValue)
            }

            let duplicateReviewCSV = CSV.write([
                ["epmc_id", "include"],
                ["R3", "yes"],
                ["R3", "no"],
            ])
            let duplicateReviewPath = ws.exportsDir.appendingPathComponent("review_duplicate.csv")
            try duplicateReviewCSV.write(to: duplicateReviewPath, atomically: true, encoding: .utf8)
            let duplicatePlan = try ArticleIO.preflightReviewedCSV(safeReviewDB, csvPath: duplicateReviewPath)
            check("复筛预检：重复 epmc_id 阻止导入", !duplicatePlan.canApply && duplicatePlan.issues.contains { $0.kind == .duplicateEPMCID })

            let missingIDReviewCSV = CSV.write([
                ["epmc_id", "include", "tags"],
                ["", "yes", "missing id"],
            ])
            let missingIDReviewPath = ws.exportsDir.appendingPathComponent("review_missing_id.csv")
            try missingIDReviewCSV.write(to: missingIDReviewPath, atomically: true, encoding: .utf8)
            let missingIDPlan = try ArticleIO.preflightReviewedCSV(safeReviewDB, csvPath: missingIDReviewPath)
            check("复筛预检：缺 epmc_id 阻止导入", !missingIDPlan.canApply && missingIDPlan.issues.contains { $0.kind == .missingEPMCID })

            let noIDColumnCSV = CSV.write([
                ["pmid", "include"],
                ["PMID-R3", "yes"],
            ])
            let noIDColumnPath = ws.exportsDir.appendingPathComponent("review_no_epmc_id.csv")
            try noIDColumnCSV.write(to: noIDColumnPath, atomically: true, encoding: .utf8)
            let noIDColumnPlan = try ArticleIO.preflightReviewedCSV(safeReviewDB, csvPath: noIDColumnPath)
            check("复筛预检：不回退 pmid/doi 匹配", !noIDColumnPlan.canApply && noIDColumnPlan.missingExpectedColumns.contains("epmc_id"))

            let tagsOnlyCSV = CSV.write([
                ["epmc_id", "tags"],
                ["R3", "free text tag"],
            ])
            let tagsOnlyPath = ws.exportsDir.appendingPathComponent("review_tags_only.csv")
            try tagsOnlyCSV.write(to: tagsOnlyPath, atomically: true, encoding: .utf8)
            let tagsOnlyPlan = try ArticleIO.preflightReviewedCSV(safeReviewDB, csvPath: tagsOnlyPath)
            check("复筛预检：允许只导入 tags", tagsOnlyPlan.canApply && tagsOnlyPlan.updates.first?.tags == "free text tag")

            let ignoredOnlyCSV = CSV.write([
                ["epmc_id", "include", "tags", "title"],
                ["", "", "", "只是阅读备注，不导回"],
            ])
            let ignoredOnlyPath = ws.exportsDir.appendingPathComponent("review_ignored_only.csv")
            try ignoredOnlyCSV.write(to: ignoredOnlyPath, atomically: true, encoding: .utf8)
            let ignoredOnlyPlan = try ArticleIO.preflightReviewedCSV(safeReviewDB, csvPath: ignoredOnlyPath)
            check("复筛预检：仅改阅读列且无 ID 时忽略", ignoredOnlyPlan.canApply && ignoredOnlyPlan.unchangedRows == 1)

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

            // 批量分类解析（多篇一次）
            let bc = AIClient.parseBatchClassify(
                "[{\"id\":1,\"q1\":{\"answer\":\"是\",\"reason\":\"r1\"},\"q2\":{\"answer\":\"否\",\"reason\":\"r2\"}},"
                + "{\"id\":2,\"q1\":{\"answer\":\"否\",\"reason\":\"x\"},\"q2\":{\"answer\":\"是\",\"reason\":\"y\"}}]",
                questions: cfg.classify.questions, idToEpmc: [1: "A", 2: "B"])
            check("批量分类解析 A q1=是", bc["A"]?["q1"]?.answer == "是")
            check("批量分类解析 B q2=是", bc["B"]?["q2"]?.answer == "是")
            let bcIncomplete = AIClient.parseBatchClassify(
                "[{\"id\":1,\"q1\":{\"answer\":\"是\",\"reason\":\"r\"}}]",
                questions: cfg.classify.questions, idToEpmc: [1: "A"])
            check("批量分类：缺问题的整篇丢弃", bcIncomplete.isEmpty)

            // CSV 健壮性：写入器转义 + 读取器宽容（防止野引号吞行、丢标注）
            let tricky = [
                ["epmc_id", "include", "tags"],
                ["E1", "yes", "含逗号,和\"引号\"与\n换行"],
                ["E2", "no", "中文，逗号与裸引号P2\"特异性"],
            ]
            let rt = CSV.parse(CSV.write(tricky))
            check("CSV 往返行数=3", rt.count == 3)
            check("CSV 往返保真：逗号/引号/换行", rt[1][2] == "含逗号,和\"引号\"与\n换行")
            check("CSV 往返保真：中文裸引号", rt[2][2] == "中文，逗号与裸引号P2\"特异性")
            // 畸形输入（未转义、未包裹的裸引号）不应吞掉后续行
            let malformed = "a,b,c\r\nx,P2\"specificity here,z\r\nq,r,s\r\n"
            let mrows = CSV.parse(malformed)
            check("宽容解析：野引号不吞行（3 行）", mrows.count == 3)
            check("宽容解析：裸引号字段保真", mrows[1][1] == "P2\"specificity here")
            check("宽容解析：后续行完整", mrows[2] == ["q", "r", "s"])

            // 检索渠道 article_terms：同一篇被期刊+关键词命中应各记一条（不因文章去重而丢渠道）
            let chDB = try Database(path: tmp.appendingPathComponent("ch.db"), config: cfg)
            let chDL = tmp.appendingPathComponent("ch_downloads")
            try FileManager.default.createDirectory(at: chDL, withIntermediateDirectories: true)
            try "{\"id\":\"K1\",\"pmid\":\"600\",\"title\":\"t1\",\"query_search_term\":\"Nature\"}"
                .write(to: chDL.appendingPathComponent("epmc_journals_t.jsonl"), atomically: true, encoding: .utf8)
            try ["{\"id\":\"K1\",\"pmid\":\"600\",\"title\":\"t1\",\"query_search_term\":\"kw alpha\"}",
                 "{\"id\":\"K2\",\"pmid\":\"601\",\"title\":\"t2\",\"query_search_term\":\"kw alpha\"}"]
                .joined(separator: "\n")
                .write(to: chDL.appendingPathComponent("epmc_keywords_t.jsonl"), atomically: true, encoding: .utf8)
            _ = try Pipeline.mergeJSONL(db: chDB, downloadsDir: chDL, reporter: nil)
            check("渠道：多渠道累积=3（K1×期刊/关键词 + K2×关键词）", try chDB.articleTermsCount() == 3)
            check("渠道：关键词产出 kw alpha total=2",
                  try chDB.keywordTermStats().contains { $0.term == "kw alpha" && $0.total == 2 })
            let rb = try Pipeline.rebuildArticleTerms(db: chDB, downloadsDir: chDL, reporter: nil)
            check("渠道：从 _merged 重建后命中对仍=3", try chDB.articleTermsCount() == 3)
            check("渠道：重建处理文件=2", rb.files == 2)
        } catch {
            failed += 1
            print("  ✗ 异常：\(error)")
        }

        cleanup()
        print("\n结果：\(passed) 通过，\(failed) 失败")
        exit(failed == 0 ? 0 : 1)
    }
}

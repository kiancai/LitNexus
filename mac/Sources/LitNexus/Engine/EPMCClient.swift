import Foundation

// Europe PMC API 客户端，对应 Python 参考的 epmc.py（游标分页 + 重试 → JSONL）。

enum EPMCClient {
    static let apiURL = "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
    static let pageRetries = 3
    static let pageBackoff = 3.0   // 每次重试固定等待 3 秒

    static func buildDateQuery(days: Int) -> String {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return "FIRST_PDATE:[\(fmt.string(from: start)) TO 2099-12-31]"
    }

    static func loadQueryFile(_ path: URL) -> [String] {
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return filterQueries(content.components(separatedBy: "\n"))
    }

    /// 过滤掉注释行（# 开头）与空行，去首尾空白。
    static func filterQueries(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// 对单个 query 分页抓取，写入 fileHandle（JSONL）。返回 (总数, 是否完整)。
    static func fetchArticles(query: String, label: String, cfg: DownloadConfig,
                              fileHandle: FileHandle, reporter: ProgressReporter?) -> (total: Int, complete: Bool) {
        var cursorMark = "*"
        var page = 1
        var total = 0
        var complete = true

        while true {
            if reporter?.isCancelled() == true { complete = false; break }
            var comps = URLComponents(string: apiURL)!
            comps.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "pageSize", value: String(cfg.pageSize)),
                URLQueryItem(name: "resultType", value: "core"),
                URLQueryItem(name: "cursorMark", value: cursorMark),
                URLQueryItem(name: "sort_date", value: "y"),
            ]
            guard let url = comps.url else { break }

            var data: [String: Any]?
            for attempt in 0...pageRetries {
                do {
                    data = try HTTP.getJSON(url, timeout: 30) as? [String: Any]
                    break
                } catch {
                    if attempt < pageRetries {
                        reporter?.log("  第 \(page) 页请求失败，\(Int(pageBackoff)) 秒后第 \(attempt + 1)/\(pageRetries) 次重试…")
                        Thread.sleep(forTimeInterval: pageBackoff)
                        continue
                    }
                    reporter?.warn("「\(label.prefix(40))」第 \(page) 页重试 \(pageRetries) 次仍失败，结果不完整（已抓 \(total) 篇）")
                    complete = false
                }
            }
            guard let payload = data else { break }

            let resultList = payload["resultList"] as? [String: Any]
            let results = resultList?["result"] as? [[String: Any]] ?? []
            if results.isEmpty {
                if page == 1 { reporter?.log("  找到 0 篇文章。") }
                break
            }

            if page == 1 {
                let hit = (payload["hitCount"] as? Int) ?? 0
                reporter?.log("  找到 \(hit) 篇文章。")
            }

            for var article in results {
                article["query_search_term"] = label
                if let line = try? JSONSerialization.data(withJSONObject: article),
                   var s = String(data: line, encoding: .utf8) {
                    s += "\n"
                    if let d = s.data(using: .utf8) { fileHandle.write(d) }
                }
            }
            total += results.count

            let next = payload["nextCursorMark"] as? String
            if next == nil || next == cursorMark { break }
            cursorMark = next!
            page += 1
            Thread.sleep(forTimeInterval: cfg.requestDelay)
        }

        return (total, complete)
    }

    // 下载结果：分项文章数（原始命中，未去重）+ 生成的 JSONL 文件。
    struct DownloadResult {
        var journalCount = 0
        var keywordCount = 0
        var files: [URL] = []
    }

    /// 执行下载，结果写入 ws.downloadsDir，返回各来源命中数与生成的 JSONL 文件路径。
    @discardableResult
    static func runDownload(config cfg: AppConfig, workspace ws: Workspace,
                            mode: String = "all", days: Int? = nil,
                            reporter: ProgressReporter? = nil) throws -> DownloadResult {
        let days = days ?? cfg.download.days
        let dateQuery = buildDateQuery(days: days)
        try ws.ensureDirs()
        let ts = timestamp()
        var result = DownloadResult()

        // 检索式现从配置读取（已统一进 litnexus.toml）。进度按「检索式个数」推进。
        let journals = (mode == "journals" || mode == "all") ? filterQueries(cfg.download.journals) : []
        let keywordTerms = (mode == "keywords" || mode == "all") ? filterQueries(cfg.download.keywords) : []
        let totalQueries = journals.count + keywordTerms.count
        let taskID = reporter?.addTask("下载文献（按检索式）", total: totalQueries)

        func openFile(_ url: URL) throws -> FileHandle {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return try FileHandle(forWritingTo: url)
        }

        let totalKeywords = keywordTerms.count

        if !journals.isEmpty {
            let out = ws.downloadsDir.appendingPathComponent("epmc_journals_\(ts).jsonl")
            let fh = try openFile(out)
            var totalCount = 0
            for (idx, journal) in journals.enumerated() {
                if reporter?.isCancelled() == true { break }
                reporter?.subProgress(key: "journals", label: "期刊", current: idx, total: journals.count, item: journal)
                reporter?.log("\n--- 抓取期刊：\(journal) ---")
                let q = "JOURNAL:\"\(journal)\" AND \(dateQuery)"
                let (n, _) = fetchArticles(query: q, label: journal, cfg: cfg.download, fileHandle: fh, reporter: reporter)
                totalCount += n
                if let taskID { reporter?.update(taskID, advance: 1) }
            }
            reporter?.subProgress(key: "journals", label: "期刊", current: journals.count, total: journals.count, item: "完成")
            try? fh.close()
            reporter?.log("\n期刊下载完成，共 \(totalCount) 篇 → \(out.lastPathComponent)")
            result.journalCount = totalCount
            result.files.append(out)
        }

        if !keywordTerms.isEmpty, reporter?.isCancelled() != true {
            let out = ws.downloadsDir.appendingPathComponent("epmc_keywords_\(ts).jsonl")
            let fh = try openFile(out)
            var totalCount = 0
            for (idx, term) in keywordTerms.enumerated() {
                if reporter?.isCancelled() == true { break }
                let label = term.count > 50 ? String(term.prefix(50)) + "…" : term
                reporter?.subProgress(key: "keywords", label: "关键词", current: idx, total: totalKeywords, item: label)
                reporter?.log("\n--- 抓取检索式：\(label) ---")
                let q = "(\(term)) AND \(dateQuery)"
                let (n, _) = fetchArticles(query: q, label: term, cfg: cfg.download, fileHandle: fh, reporter: reporter)
                totalCount += n
                if let taskID { reporter?.update(taskID, advance: 1) }
            }
            reporter?.subProgress(key: "keywords", label: "关键词", current: totalKeywords, total: totalKeywords, item: "完成")
            try? fh.close()
            reporter?.log("\n关键词下载完成，共 \(totalCount) 篇 → \(out.lastPathComponent)")
            result.keywordCount = totalCount
            result.files.append(out)
        }

        if let taskID { reporter?.complete(taskID) }
        if reporter?.isCancelled() == true { throw PipelineCancelled() }
        return result
    }

    static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }
}

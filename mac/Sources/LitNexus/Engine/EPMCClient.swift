import Foundation

// Europe PMC API 客户端，对应 Python 参考的 epmc.py（游标分页 + 重试 → JSONL）。

enum EPMCClient {
    static let apiURL = "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
    static let pageRetries = 3
    static let pageBackoff = 2.0

    static func buildDateQuery(days: Int) -> String {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return "FIRST_PDATE:[\(fmt.string(from: start)) TO 2099-12-31]"
    }

    static func loadQueryFile(_ path: URL) -> [String] {
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// 对单个 query 分页抓取，写入 fileHandle（JSONL）。返回 (总数, 是否完整)。
    static func fetchArticles(query: String, label: String, cfg: DownloadConfig,
                              fileHandle: FileHandle, reporter: ProgressReporter?) -> (total: Int, complete: Bool) {
        var cursorMark = "*"
        var page = 1
        var total = 0
        var complete = true
        var taskID: Int?

        while true {
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
                        Thread.sleep(forTimeInterval: pageBackoff * pow(2.0, Double(attempt)))
                        continue
                    }
                    reporter?.log("⚠ 检索式 '\(label.prefix(40))' 第 \(page) 页重试失败，结果不完整（已抓 \(total)）：\(error.localizedDescription)")
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
                taskID = reporter?.addTask(String(label.prefix(42)), total: hit)
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
            if let taskID { reporter?.update(taskID, advance: results.count) }

            let next = payload["nextCursorMark"] as? String
            if next == nil || next == cursorMark { break }
            cursorMark = next!
            page += 1
            Thread.sleep(forTimeInterval: cfg.requestDelay)
        }

        if let taskID { reporter?.complete(taskID) }
        return (total, complete)
    }

    /// 执行下载，结果写入 ws.downloadsDir，返回生成的 JSONL 文件路径。
    @discardableResult
    static func runDownload(config cfg: AppConfig, workspace ws: Workspace,
                            mode: String = "all", days: Int? = nil,
                            reporter: ProgressReporter? = nil) throws -> [URL] {
        let days = days ?? cfg.download.days
        let dateQuery = buildDateQuery(days: days)
        try ws.ensureDirs()
        let ts = timestamp()
        var generated: [URL] = []

        func openFile(_ url: URL) throws -> FileHandle {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return try FileHandle(forWritingTo: url)
        }

        if mode == "journals" || mode == "all" {
            let journals = loadQueryFile(ws.journalsFile)
            if !journals.isEmpty {
                let out = ws.downloadsDir.appendingPathComponent("epmc_journals_\(ts).jsonl")
                let fh = try openFile(out)
                var totalCount = 0
                for journal in journals {
                    reporter?.log("\n--- 抓取期刊：\(journal) ---")
                    let q = "JOURNAL:\"\(journal)\" AND \(dateQuery)"
                    let (n, _) = fetchArticles(query: q, label: journal, cfg: cfg.download, fileHandle: fh, reporter: reporter)
                    totalCount += n
                }
                try? fh.close()
                reporter?.log("\n期刊下载完成，共 \(totalCount) 篇 → \(out.lastPathComponent)")
                generated.append(out)
            } else {
                reporter?.log("期刊列表为空或文件不存在。")
            }
        }

        if mode == "keywords" || mode == "all" {
            for kwFile in ws.keywordsFiles {
                let terms = loadQueryFile(kwFile)
                if terms.isEmpty { continue }
                let stem = kwFile.deletingPathExtension().lastPathComponent
                let out = ws.downloadsDir.appendingPathComponent("epmc_\(stem)_\(ts).jsonl")
                let fh = try openFile(out)
                var totalCount = 0
                for term in terms {
                    let label = term.count > 60 ? String(term.prefix(60)) + "..." : term
                    reporter?.log("\n--- 抓取检索式：\(label) ---")
                    let q = "(\(term)) AND \(dateQuery)"
                    let (n, _) = fetchArticles(query: q, label: term, cfg: cfg.download, fileHandle: fh, reporter: reporter)
                    totalCount += n
                }
                try? fh.close()
                reporter?.log("\n关键词下载完成（\(kwFile.lastPathComponent)），共 \(totalCount) 篇 → \(out.lastPathComponent)")
                generated.append(out)
            }
        }

        return generated
    }

    static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }
}

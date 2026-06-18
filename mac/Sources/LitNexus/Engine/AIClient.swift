import Foundation

// OpenAI 兼容接口客户端：标题批量翻译 + 多问题分类。对应 Python 参考的 translator.py / classifier.py。

enum AIClient {
    static let maxRetries = 5
    static let backoffBase = 2.0
    static let backoffCap = 60.0

    static func backoff(_ attempt: Int) -> Double { min(backoffBase * pow(2.0, Double(attempt)), backoffCap) }

    private static func chatEndpoint(_ baseURL: String) -> URL? {
        var b = baseURL
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: b + "/chat/completions")
    }

    enum AIError: Error { case badEndpoint, noContent }

    /// 单次对话补全，返回 content。429 限流按指数退避重试。
    static func chat(ai: AIConfig, system: String, user: String, temperature: Double) throws -> String {
        guard let endpoint = chatEndpoint(ai.baseURL) else { throw AIError.badEndpoint }
        let body: [String: Any] = [
            "model": ai.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": temperature,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let headers = ["Authorization": "Bearer \(ai.apiKey)"]

        var attempt = 0
        while true {
            do {
                let resp = try HTTP.postJSON(endpoint, headers: headers, body: data, timeout: 120) as? [String: Any]
                guard let choices = resp?["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw AIError.noContent
                }
                return content
            } catch let e as HTTPError where e.isRateLimited && attempt < maxRetries {
                Thread.sleep(forTimeInterval: backoff(attempt))
                attempt += 1
            }
        }
    }

    // ── 翻译 ──────────────────────────────────────────────────────────────────

    static let translateSystemPrompt = """
    You are a professional academic translator. \
    Translate each English article title into concise, accurate Chinese. \
    Input is a JSON array; return a JSON array of the same length in the same order. \
    Output ONLY the JSON array, no markdown, no explanation.
    Input:  [{"id": 1, "title": "..."}, ...]
    Output: [{"id": 1, "title_zh": "..."}, ...]
    """

    static func parseBatchResponse(_ content: String) -> [Int: String] {
        func fromArray(_ obj: Any?) -> [Int: String]? {
            guard let arr = obj as? [[String: Any]] else { return nil }
            var out: [Int: String] = [:]
            for item in arr {
                if let id = item["id"] as? Int, let tz = item["title_zh"] as? String { out[id] = tz }
                else if let ids = item["id"] as? String, let id = Int(ids), let tz = item["title_zh"] as? String { out[id] = tz }
            }
            return out
        }
        // 层1：直接解析
        if let data = content.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data), let r = fromArray(obj), !r.isEmpty {
            return r
        }
        // 层2：提取 ```json``` 代码块
        if let block = extractCodeBlock(content), let data = block.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data), let r = fromArray(obj), !r.isEmpty {
            return r
        }
        // 层3：逐条正则
        var result: [Int: String] = [:]
        let pattern = "\"id\"\\s*:\\s*(\\d+).*?\"title_zh\"\\s*:\\s*\"(.*?)\""
        if let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            let ns = content as NSString
            for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
                if let id = Int(ns.substring(with: m.range(at: 1))) {
                    result[id] = ns.substring(with: m.range(at: 2))
                }
            }
        }
        return result
    }

    static func translateSingle(ai: AIConfig, title: String) -> String? {
        let sys = "You are a professional academic translator. Translate the English article title into concise, accurate Chinese. Output ONLY the translation."
        return (try? chat(ai: ai, system: sys, user: title, temperature: 0.1))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func translateBatch(ai: AIConfig, batch: [(epmcID: String, title: String)]) -> [(epmcID: String, titleZh: String?)] {
        var idToEpmc: [Int: String] = [:]
        var payload: [[String: Any]] = []
        for (i, item) in batch.enumerated() {
            idToEpmc[i + 1] = item.epmcID
            payload.append(["id": i + 1, "title": item.title])
        }
        let userMsg: String
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            userMsg = String(data: data, encoding: .utf8) ?? "[]"
        } else { userMsg = "[]" }

        let content: String
        do {
            content = try chat(ai: ai, system: translateSystemPrompt, user: userMsg, temperature: 0.1)
        } catch {
            return batch.map { ($0.epmcID, nil) }  // 整批失败：保持未翻译，下次重试
        }

        let parsed = parseBatchResponse(content)
        let titleByEpmc = Dictionary(uniqueKeysWithValues: batch.map { ($0.epmcID, $0.title) })
        var results: [(String, String?)] = []
        for (localID, epmcID) in idToEpmc.sorted(by: { $0.key < $1.key }) {
            if let tz = parsed[localID] {
                results.append((epmcID, tz))
            } else {
                results.append((epmcID, translateSingle(ai: ai, title: titleByEpmc[epmcID] ?? "")))
            }
        }
        return results
    }

    static func runTranslation(db: Database, config tcfg: TranslateConfig, ai: AIConfig,
                               reporter: ProgressReporter?) throws -> (translated: Int, failed: Int) {
        let pending = try db.fetchPendingTranslations()
        if pending.isEmpty { reporter?.log("没有需要翻译的文章。"); return (0, 0) }
        reporter?.log("共 \(pending.count) 篇待翻译（批量 \(tcfg.batchSize)）")

        var batches: [[(epmcID: String, title: String)]] = []
        var i = 0
        while i < pending.count {
            batches.append(Array(pending[i..<min(i + tcfg.batchSize, pending.count)]))
            i += tcfg.batchSize
        }

        let taskID = reporter?.addTask("翻译标题", total: batches.count)
        let lock = NSLock()
        var buffer: [(epmcID: String, titleZh: String?)] = []
        var translated = 0, failed = 0

        try concurrentForEach(batches, concurrency: tcfg.concurrency) { batch in
            let res = translateBatch(ai: ai, batch: batch)
            lock.lock()
            buffer.append(contentsOf: res)
            for (_, tz) in res { if tz != nil { translated += 1 } else { failed += 1 } }
            if let taskID { reporter?.update(taskID, advance: 1) }
            if buffer.count >= 500 {
                let flush = buffer; buffer.removeAll()
                lock.unlock()
                try? db.updateTranslations(flush)
                return
            }
            lock.unlock()
        }
        if !buffer.isEmpty { try db.updateTranslations(buffer) }
        if let taskID { reporter?.complete(taskID) }
        return (translated, failed)
    }

    // ── 分类 ──────────────────────────────────────────────────────────────────

    static func buildSystemPrompt(_ questions: [Question]) -> String {
        let lines = questions.map {
            "  \"\($0.id)\": {\"answer\": \"是\"|\"否\", \"reason\": \"简洁理由（不超过200字）\"}"
        }.joined(separator: ",\n")
        return "你是一个严谨的科研领域分类专家。根据提供的论文标题和摘要，回答以下所有问题。"
            + "标题或摘要缺失时，仅依据现有信息判断。\n\n"
            + "你的回答必须是且仅是一个 JSON 对象，不包含任何 Markdown 或解释性文字，结构如下：\n"
            + "{\n" + lines + "\n}"
    }

    static func parseClassifyResponse(_ content: String, questions: [Question]) -> [String: (answer: String, reason: String)] {
        func extract(_ obj: Any?) -> [String: (String, String)] {
            guard let dict = obj as? [String: Any] else { return [:] }
            var out: [String: (String, String)] = [:]
            for q in questions {
                if let qd = dict[q.id] as? [String: Any] {
                    out[q.id] = ((qd["answer"] as? String) ?? "", (qd["reason"] as? String) ?? "")
                }
            }
            return out
        }
        if let data = content.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) {
            let r = extract(obj); if !r.isEmpty { return r }
        }
        if let block = extractCodeBlock(content), let data = block.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            let r = extract(obj); if !r.isEmpty { return r }
        }
        return [:]
    }

    static func classifyOne(ai: AIConfig, title: String, abstract: String, questions: [Question])
        -> [String: (answer: String, reason: String)] {
        if title.trimmingCharacters(in: .whitespaces).isEmpty
            && abstract.trimmingCharacters(in: .whitespaces).isEmpty {
            var out: [String: (String, String)] = [:]
            for q in questions { out[q.id] = ("N/A", "缺少标题和摘要") }
            return out
        }
        let qText = questions.map { "【问题 \($0.id)】\($0.text)" }.joined(separator: "\n")
        let user = "【标题】\(title)\n【摘要】\(abstract)\n\n\(qText)"
        guard let content = try? chat(ai: ai, system: buildSystemPrompt(questions), user: user, temperature: 0.0) else {
            return [:]  // 失败不落库，保持 NULL 下次重试
        }
        return parseClassifyResponse(content, questions: questions)
    }

    static func runClassification(db: Database, config ccfg: ClassifyConfig, ai: AIConfig,
                                  reporter: ProgressReporter?) throws -> (processed: Int, failed: Int) {
        let questions = ccfg.questions
        if questions.isEmpty { reporter?.log("未配置任何问题，跳过分类。"); return (0, 0) }
        let pending = try db.fetchPendingClassification(questions)
        if pending.isEmpty { reporter?.log("没有需要分类的文章。"); return (0, 0) }
        reporter?.log("共 \(pending.count) 篇待分类")

        let taskID = reporter?.addTask("AI 分类", total: pending.count)
        let lock = NSLock()
        var buffer: [(epmcID: String, results: [String: (answer: String, reason: String)])] = []
        var processed = 0, failed = 0

        try concurrentForEach(pending, concurrency: max(1, ccfg.maxWorkers)) { row in
            let results = classifyOne(ai: ai, title: row.title, abstract: row.abstract, questions: questions)
            lock.lock()
            if results.isEmpty {
                failed += 1
            } else {
                buffer.append((row.epmcID, results)); processed += 1
            }
            if let taskID { reporter?.update(taskID, advance: 1) }
            if buffer.count >= 50 {
                let flush = buffer; buffer.removeAll()
                lock.unlock()
                try? db.writeClassification(flush)
                return
            }
            lock.unlock()
        }
        if !buffer.isEmpty { try db.writeClassification(buffer) }
        if let taskID { reporter?.complete(taskID) }
        return (processed, failed)
    }

    // ── 工具 ──────────────────────────────────────────────────────────────────

    static func extractCodeBlock(_ content: String) -> String? {
        let pattern = "```(?:json)?\\s*([\\s\\S]*?)```"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = content as NSString
        guard let m = re.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// 限并发地处理每个元素（信号量 + DispatchGroup）。body 在后台线程执行。
    static func concurrentForEach<T>(_ items: [T], concurrency: Int, _ body: @escaping (T) -> Void) throws {
        let sem = DispatchSemaphore(value: max(1, concurrency))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "litnexus.ai", attributes: .concurrent)
        for item in items {
            sem.wait()
            group.enter()
            queue.async {
                body(item)
                sem.signal()
                group.leave()
            }
        }
        group.wait()
    }
}

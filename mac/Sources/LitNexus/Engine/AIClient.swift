import Foundation

// OpenAI 兼容接口客户端：标题批量翻译 + 多问题分类。对应 Python 参考的 translator.py / classifier.py。

enum AIClient {
    static let maxRetries = 5
    static let backoffBase = 2.0
    static let backoffCap = 60.0

    static func backoff(_ attempt: Int) -> Double { min(backoffBase * pow(2.0, Double(attempt)), backoffCap) }

    private static func chatEndpoint(_ baseURL: String) -> URL? {
        var b = baseURL.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        // 容错：用户填到 /v1 或填完整的 /chat/completions 都能认。
        if b.hasSuffix("/chat/completions") { return URL(string: b) }
        return URL(string: b + "/chat/completions")
    }

    enum AIError: Error, LocalizedError {
        case badEndpoint, noContent
        case message(String)
        var errorDescription: String? {
            switch self {
            case .badEndpoint: return "AI 接口地址无效"
            case .noContent: return "AI 未返回内容"
            case .message(let m): return m
            }
        }
    }

    /// 单次对话补全，返回 content。429 限流按指数退避重试。
    static func chat(ai: AIConfig, system: String, user: String, temperature: Double) throws -> String {
        guard let endpoint = chatEndpoint(ai.baseURL) else { throw AIError.badEndpoint }
        var body: [String: Any] = [
            "model": ai.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": temperature,
        ]
        // 合并用户的额外参数（如关推理开关），用户写的键可覆盖默认值。
        let trimmed = ai.extraParams.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let d = trimmed.data(using: .utf8),
           let extra = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in extra { body[k] = v }
        }
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

    // 一个可翻译字段的描述（标题或摘要）。统一用 text/text_zh 作 JSON 线协议字段名。
    struct TranslateField {
        let noun: String        // 英文名词，写进 prompt，如 "title" / "abstract"
        let textColumn: String  // 源列：title / abstract
        let zhColumn: String    // 译文列：title_zh / abstract_zh
        let label: String       // 进度条标签：翻译标题 / 翻译摘要
        let batchSize: (TranslateConfig) -> Int

        static let title = TranslateField(noun: "title", textColumn: "title", zhColumn: "title_zh",
                                          label: "翻译标题", batchSize: { $0.batchSize })
        static let abstract = TranslateField(noun: "abstract", textColumn: "abstract", zhColumn: "abstract_zh",
                                             label: "翻译摘要", batchSize: { max(1, $0.abstractBatchSize) })
    }

    static func translateSystemPrompt(_ noun: String) -> String {
        """
        You are a professional academic translator. \
        Translate each English article \(noun) into concise, accurate Chinese. \
        Input is a JSON array; return a JSON array of the same length in the same order. \
        Output ONLY the JSON array, no markdown, no explanation.
        Input:  [{"id": 1, "text": "..."}, ...]
        Output: [{"id": 1, "text_zh": "..."}, ...]
        """
    }

    // 兼容旧测试默认 "title_zh"；新管线统一用 "text_zh"。
    static func parseBatchResponse(_ content: String, valueKey: String = "title_zh") -> [Int: String] {
        func fromArray(_ obj: Any?) -> [Int: String]? {
            guard let arr = obj as? [[String: Any]] else { return nil }
            var out: [Int: String] = [:]
            for item in arr {
                let tz = (item[valueKey] as? String) ?? (item["text_zh"] as? String) ?? (item["title_zh"] as? String)
                guard let tz else { continue }
                if let id = item["id"] as? Int { out[id] = tz }
                else if let ids = item["id"] as? String, let id = Int(ids) { out[id] = tz }
            }
            return out
        }
        if let data = content.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data), let r = fromArray(obj), !r.isEmpty {
            return r
        }
        if let block = extractCodeBlock(content), let data = block.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data), let r = fromArray(obj), !r.isEmpty {
            return r
        }
        var result: [Int: String] = [:]
        let pattern = "\"id\"\\s*:\\s*(\\d+).*?\"(?:text_zh|title_zh)\"\\s*:\\s*\"(.*?)\""
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

    static func translateSingle(ai: AIConfig, noun: String, text: String) -> String? {
        let sys = "You are a professional academic translator. Translate the English article \(noun) into concise, accurate Chinese. Output ONLY the translation."
        return (try? chat(ai: ai, system: sys, user: text, temperature: 0.1))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func translateBatch(ai: AIConfig, noun: String, batch: [(epmcID: String, title: String)])
        -> (results: [(epmcID: String, titleZh: String?)], error: String?) {
        var idToEpmc: [Int: String] = [:]
        var payload: [[String: Any]] = []
        for (i, item) in batch.enumerated() {
            idToEpmc[i + 1] = item.epmcID
            payload.append(["id": i + 1, "text": item.title])
        }
        let userMsg: String
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            userMsg = String(data: data, encoding: .utf8) ?? "[]"
        } else { userMsg = "[]" }

        let content: String
        do {
            content = try chat(ai: ai, system: translateSystemPrompt(noun), user: userMsg, temperature: 0.1)
        } catch {
            return (batch.map { ($0.epmcID, nil) }, (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        let parsed = parseBatchResponse(content, valueKey: "text_zh")
        let textByEpmc = Dictionary(uniqueKeysWithValues: batch.map { ($0.epmcID, $0.title) })
        var results: [(String, String?)] = []
        for (localID, epmcID) in idToEpmc.sorted(by: { $0.key < $1.key }) {
            if let tz = parsed[localID] {
                results.append((epmcID, tz))
            } else {
                results.append((epmcID, translateSingle(ai: ai, noun: noun, text: textByEpmc[epmcID] ?? "")))
            }
        }
        return (results, nil)
    }

    /// 翻译标题（始终）+ 摘要（按配置）。返回累计 (已译, 失败)。
    static func runTranslation(db: Database, config tcfg: TranslateConfig, ai: AIConfig,
                               reporter: ProgressReporter?) throws -> (translated: Int, failed: Int) {
        var fields: [TranslateField] = [.title]
        if tcfg.translateAbstract { fields.append(.abstract) }

        var totalTranslated = 0, totalFailed = 0
        var anyPending = false
        var lastHardError: String?

        for field in fields {
            let pending = try db.fetchPendingTranslations(textColumn: field.textColumn, zhColumn: field.zhColumn)
            if pending.isEmpty { reporter?.log("\(field.label)：没有需要翻译的文章。"); continue }
            anyPending = true
            let bs = field.batchSize(tcfg)
            reporter?.log("\(field.label)：共 \(pending.count) 篇待翻译（批量 \(bs)）")

            var batches: [[(epmcID: String, title: String)]] = []
            var i = 0
            while i < pending.count {
                batches.append(Array(pending[i..<min(i + bs, pending.count)]))
                i += bs
            }

            let subLabel = field.noun == "title" ? "标题" : "摘要"
            let taskID = reporter?.addTask(field.label, total: pending.count)
            reporter?.subProgress(key: field.zhColumn, label: subLabel, current: 0, total: pending.count, item: "进行中")
            let lock = NSLock()
            var buffer: [(epmcID: String, titleZh: String?)] = []
            var translated = 0, failed = 0
            var lastError: String?

            try concurrentForEach(batches, concurrency: tcfg.concurrency) { batch in
                let (res, err) = translateBatch(ai: ai, noun: field.noun, batch: batch)
                lock.lock()
                if let err, lastError == nil { lastError = err }
                buffer.append(contentsOf: res)
                for (_, tz) in res { if tz != nil { translated += 1 } else { failed += 1 } }
                if let taskID { reporter?.update(taskID, advance: batch.count) }
                reporter?.subProgress(key: field.zhColumn, label: subLabel, current: translated + failed, total: pending.count, item: "进行中")
                if buffer.count >= 500 {
                    let flush = buffer; buffer.removeAll()
                    lock.unlock()
                    try? db.updateTranslations(flush, column: field.zhColumn)
                    return
                }
                lock.unlock()
            }
            if !buffer.isEmpty { try db.updateTranslations(buffer, column: field.zhColumn) }
            if let taskID { reporter?.complete(taskID) }
            reporter?.subProgress(key: field.zhColumn, label: subLabel, current: pending.count, total: pending.count, item: "完成")

            totalTranslated += translated; totalFailed += failed
            if translated == 0, failed > 0, lastHardError == nil {
                lastHardError = "\(field.label)全部失败（\(failed) 篇）：\(lastError ?? "未知错误")"
            }
        }

        if !anyPending { reporter?.log("没有需要翻译的文章。"); return (0, 0) }
        // 整体一篇都没成、却有失败 → 抛真实原因（通常是接口/密钥问题）
        if totalTranslated == 0, totalFailed > 0 {
            throw AIError.message(lastHardError ?? "翻译全部失败：未知错误")
        }
        return (totalTranslated, totalFailed)
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
        -> (results: [String: (answer: String, reason: String)], error: String?) {
        if title.trimmingCharacters(in: .whitespaces).isEmpty
            && abstract.trimmingCharacters(in: .whitespaces).isEmpty {
            var out: [String: (String, String)] = [:]
            for q in questions { out[q.id] = ("N/A", "缺少标题和摘要") }
            return (out, nil)
        }
        let qText = questions.map { "【问题 \($0.id)】\($0.text)" }.joined(separator: "\n")
        let user = "【标题】\(title)\n【摘要】\(abstract)\n\n\(qText)"
        do {
            let content = try chat(ai: ai, system: buildSystemPrompt(questions), user: user, temperature: 0.0)
            let r = parseClassifyResponse(content, questions: questions)
            return r.isEmpty ? ([:], "解析结果为空") : (r, nil)
        } catch {
            return ([:], (error as? LocalizedError)?.errorDescription ?? "\(error)")  // 不落库，下次重试
        }
    }

    static func runClassification(db: Database, config ccfg: ClassifyConfig, ai: AIConfig,
                                  reporter: ProgressReporter?) throws -> (processed: Int, failed: Int) {
        let questions = ccfg.questions.filter { $0.classify }   // 仅处理「AI 处理=开」的问题
        if questions.isEmpty { reporter?.log("没有启用的分类问题，跳过分类。"); return (0, 0) }
        let pending = try db.fetchPendingClassification(questions)
        if pending.isEmpty { reporter?.log("没有需要分类的文章。"); return (0, 0) }
        reporter?.log("共 \(pending.count) 篇待分类")

        let taskID = reporter?.addTask("AI 分类", total: pending.count)
        let lock = NSLock()
        var buffer: [(epmcID: String, results: [String: (answer: String, reason: String)])] = []
        var processed = 0, failed = 0
        var lastError: String?

        try concurrentForEach(pending, concurrency: max(1, ccfg.maxWorkers)) { row in
            let (results, err) = classifyOne(ai: ai, title: row.title, abstract: row.abstract, questions: questions)
            lock.lock()
            if results.isEmpty {
                failed += 1
                if let err, lastError == nil { lastError = err }
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
        if processed == 0, failed > 0 {
            throw AIError.message("分类全部失败（\(failed) 篇）：\(lastError ?? "未知错误")")
        }
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

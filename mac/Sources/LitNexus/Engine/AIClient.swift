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

    // ── 批量分类 ──────────────────────────────────────────────────────────────

    typealias QResults = [String: (answer: String, reason: String)]

    static func isParseFailure(_ e: String?) -> Bool { (e ?? "").contains("解析") }

    static func buildBatchClassifyPrompt(_ questions: [Question]) -> String {
        let qlist = questions.map { "【\($0.id)】\($0.text)" }.joined(separator: "\n")
        let schema = questions.map { "\"\($0.id)\": {\"answer\": \"是\"|\"否\", \"reason\": \"简洁理由（不超过200字）\"}" }
            .joined(separator: ", ")
        return """
        你是一个严谨的科研领域分类专家。我会给你一个 JSON 数组，每个元素是一篇文章，含 id、title、abstract。
        请对每一篇文章回答下列所有问题，仅依据其标题与摘要判断；标题或摘要缺失时只用现有信息。

        问题：
        \(qlist)

        只输出一个 JSON 数组，长度与输入相同、顺序一致，每个元素形如：
        {"id": <对应文章的id>, \(schema)}
        不要输出任何额外文字、解释或 Markdown。
        """
    }

    static func parseBatchClassify(_ content: String, questions: [Question], idToEpmc: [Int: String]) -> [String: QResults] {
        func fromArray(_ obj: Any?) -> [String: QResults] {
            guard let arr = obj as? [[String: Any]] else { return [:] }
            var out: [String: QResults] = [:]
            for item in arr {
                let localID: Int? = (item["id"] as? Int) ?? (item["id"] as? String).flatMap { Int($0) }
                guard let lid = localID, let epmc = idToEpmc[lid] else { continue }
                var res: QResults = [:]
                for q in questions {
                    if let qd = item[q.id] as? [String: Any], let a = qd["answer"] as? String, !a.isEmpty {
                        res[q.id] = (a, (qd["reason"] as? String) ?? "")
                    }
                }
                if res.count == questions.count { out[epmc] = res }   // 全部问题都答了才算这篇成功
            }
            return out
        }
        if let data = content.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) {
            let r = fromArray(obj); if !r.isEmpty { return r }
        }
        if let block = extractCodeBlock(content), let data = block.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            let r = fromArray(obj); if !r.isEmpty { return r }
        }
        return [:]
    }

    /// 一次调用分类多篇。返回 (按 epmcID 索引的成功结果, 错误)。
    static func classifyBatch(ai: AIConfig, batch: [(epmcID: String, title: String, abstract: String)],
                              questions: [Question]) -> (parsed: [String: QResults], error: String?) {
        var idToEpmc: [Int: String] = [:]
        var payload: [[String: Any]] = []
        for (i, art) in batch.enumerated() {
            idToEpmc[i + 1] = art.epmcID
            payload.append(["id": i + 1, "title": art.title, "abstract": art.abstract])
        }
        let userMsg = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let content: String
        do { content = try chat(ai: ai, system: buildBatchClassifyPrompt(questions), user: userMsg, temperature: 0.0) }
        catch { return ([:], (error as? LocalizedError)?.errorDescription ?? "\(error)") }
        let parsed = parseBatchClassify(content, questions: questions, idToEpmc: idToEpmc)
        return parsed.isEmpty ? ([:], "解析结果为空") : (parsed, nil)
    }

    /// 逐篇兜底（带重试），用于隔离“批量里那篇毒文章”。
    static func classifyOneRetry(ai: AIConfig, title: String, abstract: String,
                                 questions: [Question], maxAttempts: Int) -> (results: QResults, error: String?) {
        var lastErr: String?
        for _ in 0..<max(1, maxAttempts) {
            let (r, e) = classifyOne(ai: ai, title: title, abstract: abstract, questions: questions)
            if !r.isEmpty { return (r, nil) }
            lastErr = e
            if !isParseFailure(e) { break }   // API/网络错误：瞬时，停止重试
        }
        return ([:], lastErr)
    }

    /// 批量分类 + 容错：批量解析失败时退化为逐篇，避免一篇坏文章拖垮整批。
    static func classifyBatchWithFallback(ai: AIConfig, batch: [(epmcID: String, title: String, abstract: String)],
                                          questions: [Question], maxAttempts: Int)
        -> (success: [(epmcID: String, results: QResults)], parseFailed: [String], transient: [String]) {
        func perItem(_ items: [(epmcID: String, title: String, abstract: String)])
            -> (success: [(epmcID: String, results: QResults)], parseFailed: [String], transient: [String]) {
            var success: [(epmcID: String, results: QResults)] = []
            var parseFailed: [String] = [], transient: [String] = []
            for art in items {
                let (r, e) = classifyOneRetry(ai: ai, title: art.title, abstract: art.abstract, questions: questions, maxAttempts: maxAttempts)
                if !r.isEmpty { success.append((art.epmcID, r)) }
                else if isParseFailure(e) { parseFailed.append(art.epmcID) }
                else { transient.append(art.epmcID) }
            }
            return (success, parseFailed, transient)
        }

        var lastErr: String?
        for _ in 0..<max(1, maxAttempts) {
            let (parsed, err) = classifyBatch(ai: ai, batch: batch, questions: questions)
            lastErr = err
            if err == nil, !parsed.isEmpty {
                var success: [(epmcID: String, results: QResults)] = []
                var missing: [(epmcID: String, title: String, abstract: String)] = []
                for art in batch {
                    if let r = parsed[art.epmcID] { success.append((art.epmcID, r)) } else { missing.append(art) }
                }
                let m = perItem(missing)   // 少数缺失的逐篇兜底
                return (success + m.success, m.parseFailed, m.transient)
            }
            if !isParseFailure(err) { break }   // API 错误：停止重试整批
        }
        // 批量始终拿不到结果
        if isParseFailure(lastErr) { return perItem(batch) }        // 整批反复无法解析 → 逐篇隔离坏文章
        return ([], [], batch.map { $0.epmcID })                    // API 持续失败 → 全部瞬时
    }

    static func runClassification(db: Database, config ccfg: ClassifyConfig, ai: AIConfig,
                                  reporter: ProgressReporter?) throws -> (processed: Int, failed: Int) {
        let questions = ccfg.questions.filter { $0.classify }   // 仅处理「AI 处理=开」的问题
        if questions.isEmpty { reporter?.log("没有启用的分类问题，跳过分类。"); return (0, 0) }
        let pending = try db.fetchPendingClassification(questions)
        if pending.isEmpty { reporter?.log("没有需要分类的文章。"); return (0, 0) }

        let maxAttempts = max(1, ccfg.maxAttempts)
        let batchSize = max(1, ccfg.batchSize)
        reporter?.log("共 \(pending.count) 篇待分类（批量 \(batchSize)/次）")

        // 无标题无摘要的，直接标 N/A，不送 AI
        var toClassify: [(epmcID: String, title: String, abstract: String)] = []
        var naResults: [(epmcID: String, results: QResults)] = []
        for row in pending {
            if row.title.trimmingCharacters(in: .whitespaces).isEmpty
                && row.abstract.trimmingCharacters(in: .whitespaces).isEmpty {
                var r: QResults = [:]
                for q in questions { r[q.id] = ("N/A", "缺少标题和摘要") }
                naResults.append((row.epmcID, r))
            } else {
                toClassify.append((row.epmcID, row.title, row.abstract))
            }
        }
        if !naResults.isEmpty { try db.writeClassification(naResults) }

        var batches: [[(epmcID: String, title: String, abstract: String)]] = []
        var i = 0
        while i < toClassify.count {
            batches.append(Array(toClassify[i..<min(i + batchSize, toClassify.count)])); i += batchSize
        }

        let taskID = reporter?.addTask("AI 分类", total: pending.count)
        if let taskID, !naResults.isEmpty { reporter?.update(taskID, advance: naResults.count) }
        let lock = NSLock()
        var buffer: [(epmcID: String, results: QResults)] = []
        var processed = naResults.count, transientFailed = 0
        var parseFailedIDs: [String] = []

        try concurrentForEach(batches, concurrency: max(1, ccfg.maxWorkers)) { batch in
            let (success, parseFailed, transient) = classifyBatchWithFallback(
                ai: ai, batch: batch, questions: questions, maxAttempts: maxAttempts)
            lock.lock()
            buffer.append(contentsOf: success)
            processed += success.count
            parseFailedIDs.append(contentsOf: parseFailed)
            transientFailed += transient.count
            if let taskID { reporter?.update(taskID, advance: batch.count) }
            if buffer.count >= 50 {
                let flush = buffer; buffer.removeAll()
                lock.unlock()
                try? db.writeClassification(flush)
                return
            }
            lock.unlock()
        }
        if !buffer.isEmpty { try db.writeClassification(buffer) }

        // 本次一篇都没成功 → 视为系统性问题，抛错且不标任何「失败」，避免误伤全库。
        if processed == 0, transientFailed > 0 || !parseFailedIDs.isEmpty {
            if let taskID { reporter?.complete(taskID) }
            throw AIError.message("分类全部失败（\(transientFailed + parseFailedIDs.count) 篇）：模型输出无法解析或接口异常，请检查模型/额外参数")
        }

        // 本次有成功（证明配置正常）→ 把确定性解析失败的标为「失败」，照常入库、不再无限重试。
        var markedFailed = 0
        if !parseFailedIDs.isEmpty {
            let failBatch = parseFailedIDs.map { id -> (epmcID: String, results: QResults) in
                var r: QResults = [:]
                for q in questions { r[q.id] = (answer: "失败", reason: "多次分类解析失败") }
                return (id, r)
            }
            try db.writeClassification(failBatch)
            markedFailed = parseFailedIDs.count
            reporter?.log("⚠ \(markedFailed) 篇多次解析失败，已标记为「失败」并照常入库。")
        }
        if let taskID { reporter?.complete(taskID) }
        return (processed, transientFailed + markedFailed)
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

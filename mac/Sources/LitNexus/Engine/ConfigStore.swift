import Foundation
import TOMLKit

// litnexus.toml 的读写。
// TOML 中的 [schema] 表对应模型字段 schema。

enum ConfigError: Error, LocalizedError {
    case fileNotFound(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "配置文件不存在：\(p)"
        case .parse(let m): return "配置文件 TOML 语法错误：\(m)"
        }
    }
}

enum ConfigStore {
    static func load(_ path: URL) throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ConfigError.fileNotFound(path.path)
        }
        let content = try String(contentsOf: path, encoding: .utf8)
        let table: TOMLTable
        do {
            table = try TOMLTable(string: content)
        } catch {
            throw ConfigError.parse("\(error)")
        }

        var cfg = AppConfig()

        if let d = table["download"]?.tomlValue.table {
            cfg.download.days = d["days"]?.tomlValue.int ?? cfg.download.days
            cfg.download.pageSize = d["page_size"]?.tomlValue.int ?? cfg.download.pageSize
            cfg.download.requestDelay = d["request_delay"]?.tomlValue.double
                ?? d["request_delay"]?.tomlValue.int.map(Double.init)
                ?? cfg.download.requestDelay
            if let arr = d["journals"]?.tomlValue.array {
                cfg.download.journals = arr.compactMap { $0.tomlValue.string }
            }
            if let arr = d["keywords"]?.tomlValue.array {
                cfg.download.keywords = arr.compactMap { $0.tomlValue.string }
            }
        }
        // 旧项目迁移：toml 里没有 journals/keywords 时，从同目录的 journals.txt / keywords.txt(+keywords/) 读入。
        let hasJournalsKey = (table["download"]?.tomlValue.table?["journals"]) != nil
        let hasKeywordsKey = (table["download"]?.tomlValue.table?["keywords"]) != nil
        if !hasJournalsKey || !hasKeywordsKey {
            let ws = Workspace(root: path.deletingLastPathComponent())
            if !hasJournalsKey, let txt = try? String(contentsOf: ws.journalsFile, encoding: .utf8) {
                cfg.download.journals = txt.components(separatedBy: "\n")
            }
            if !hasKeywordsKey {
                let lines = ws.keywordsFiles.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                    .flatMap { $0.components(separatedBy: "\n") }
                if !lines.isEmpty { cfg.download.keywords = lines }
            }
        }

        if let a = table["ai"]?.tomlValue.table {
            var profiles: [AIProfile] = []
            if let arr = a["profiles"]?.tomlValue.array {
                for item in arr {
                    guard let t = item.tomlValue.table else { continue }
                    var p = AIProfile()
                    p.id = t["id"]?.tomlValue.string ?? p.id
                    p.name = t["name"]?.tomlValue.string ?? p.name
                    p.baseURL = t["base_url"]?.tomlValue.string ?? ""
                    p.model = t["model"]?.tomlValue.string ?? ""
                    p.apiKey = t["api_key"]?.tomlValue.string ?? ""
                    p.extraParams = t["extra_params"]?.tomlValue.string ?? ""
                    profiles.append(p)
                }
            }
            // 旧格式迁移：无 profiles 但存在 base_url/model/api_key
            if profiles.isEmpty {
                let base = a["base_url"]?.tomlValue.string ?? ""
                let model = a["model"]?.tomlValue.string ?? ""
                let key = a["api_key"]?.tomlValue.string ?? ""
                if !base.isEmpty || !model.isEmpty || !key.isEmpty {
                    profiles = [AIProfile(name: "默认", baseURL: base, model: model, apiKey: key,
                                          extraParams: a["extra_params"]?.tomlValue.string ?? "")]
                }
            }
            cfg.aiProfiles = profiles
            cfg.activeAIID = a["active"]?.tomlValue.string ?? profiles.first?.id ?? ""
        }

        if let t = table["translate"]?.tomlValue.table {
            cfg.translate.batchSize = t["batch_size"]?.tomlValue.int ?? cfg.translate.batchSize
            cfg.translate.concurrency = t["concurrency"]?.tomlValue.int ?? cfg.translate.concurrency
            cfg.translate.translateAbstract = t["translate_abstract"]?.tomlValue.bool ?? cfg.translate.translateAbstract
            cfg.translate.abstractBatchSize = t["abstract_batch_size"]?.tomlValue.int ?? cfg.translate.abstractBatchSize
        }

        if let c = table["classify"]?.tomlValue.table {
            cfg.classify.maxWorkers = c["max_workers"]?.tomlValue.int ?? cfg.classify.maxWorkers
            cfg.classify.batchSize = c["batch_size"]?.tomlValue.int ?? cfg.classify.batchSize
            cfg.classify.maxAttempts = c["max_attempts"]?.tomlValue.int ?? cfg.classify.maxAttempts
            // `next_question_number` 是问题 id 的持久化高水位。旧项目没有该字段时，
            // 稍后会由现存 q<N> 自动推断，首次保存后补写入 TOML。
            if let next = c["next_question_number"]?.tomlValue.int {
                cfg.classify.nextQuestionNumber = next
            }
            if let qs = c["questions"]?.tomlValue.array {
                var questions: [Question] = []
                for item in qs {
                    if let qt = item.tomlValue.table,
                       let id = qt["id"]?.tomlValue.string,
                       let text = qt["text"]?.tomlValue.string {
                        questions.append(Question(
                            id: id,
                            nickname: qt["nickname"]?.tomlValue.string ?? "",
                            text: text,
                            classify: qt["classify"]?.tomlValue.bool ?? true,
                            export: qt["export"]?.tomlValue.bool ?? true,
                            archived: qt["archived"]?.tomlValue.bool ?? false,
                            classifyAfterRowID: qt["classify_after_rowid"]?.tomlValue.int.flatMap { $0 >= 0 ? $0 : nil }))
                    }
                }
                cfg.classify.questions = questions
            }
            cfg.classify.normalizeQuestionIDAllocator()
        }

        if let s = table["schema"]?.tomlValue.table,
           let cols = s["custom_columns"]?.tomlValue.array {
            cfg.schema.customColumns = cols.compactMap { $0.tomlValue.string }
        }
        cfg.schema.customColumns = SchemaConfig.normalizedAnnotationColumns(cfg.schema.customColumns)

        if let e = table["export"]?.tomlValue.table {
            cfg.export.filter = e["filter"]?.tomlValue.string ?? cfg.export.filter
            if let cols = e["exclude_columns"]?.tomlValue.array {
                cfg.export.excludeColumns = cols.compactMap { $0.tomlValue.string }
            }
        }

        if let theme = table["theme"]?.tomlValue.table {
            let hue = theme["accent_hue"]?.tomlValue.double
                ?? theme["accent_hue"]?.tomlValue.int.map(Double.init)
            cfg.theme.accentHue = ThemeConfig.normalizedAccentHue(hue)
        }

        return cfg
    }

    static func serialize(_ cfg: AppConfig) -> String {
        let root = TOMLTable()

        let download = TOMLTable()
        download["days"] = cfg.download.days
        download["page_size"] = cfg.download.pageSize
        download["request_delay"] = cfg.download.requestDelay
        let journalsArr = TOMLArray()
        for j in cfg.download.journals { journalsArr.append(j) }
        download["journals"] = journalsArr
        let keywordsArr = TOMLArray()
        for k in cfg.download.keywords { keywordsArr.append(k) }
        download["keywords"] = keywordsArr
        root["download"] = download

        let ai = TOMLTable()
        ai["active"] = cfg.activeAIID
        let profiles = TOMLArray()
        for p in cfg.aiProfiles {
            let t = TOMLTable()
            t["id"] = p.id
            t["name"] = p.name
            t["base_url"] = p.baseURL
            t["model"] = p.model
            t["api_key"] = p.apiKey
            t["extra_params"] = p.extraParams
            profiles.append(t)
        }
        ai["profiles"] = profiles
        root["ai"] = ai

        let translate = TOMLTable()
        translate["batch_size"] = cfg.translate.batchSize
        translate["concurrency"] = cfg.translate.concurrency
        translate["translate_abstract"] = cfg.translate.translateAbstract
        translate["abstract_batch_size"] = cfg.translate.abstractBatchSize
        root["translate"] = translate

        let classify = TOMLTable()
        classify["max_workers"] = cfg.classify.maxWorkers
        classify["batch_size"] = cfg.classify.batchSize
        classify["max_attempts"] = cfg.classify.maxAttempts
        // 候选值会校正手工编辑 TOML 后过低的高水位；不会改变原配置对象，
        // 但确保下一次 load 后的分配器仍不会复用已有 id。
        classify["next_question_number"] = cfg.classify.persistedNextQuestionNumber
        let questions = TOMLArray()
        for q in cfg.classify.questions {
            let qt = TOMLTable()
            qt["id"] = q.id
            qt["nickname"] = q.nickname
            qt["text"] = q.text
            qt["classify"] = q.classify
            qt["export"] = q.export
            qt["archived"] = q.archived
            if let after = q.classifyAfterRowID { qt["classify_after_rowid"] = after }
            questions.append(qt)
        }
        classify["questions"] = questions
        root["classify"] = classify

        let schema = TOMLTable()
        let customCols = TOMLArray()
        for c in SchemaConfig.normalizedAnnotationColumns(cfg.schema.customColumns) { customCols.append(c) }
        schema["custom_columns"] = customCols
        root["schema"] = schema

        let export = TOMLTable()
        export["filter"] = cfg.export.filter
        let excl = TOMLArray()
        for c in cfg.export.excludeColumns { excl.append(c) }
        export["exclude_columns"] = excl
        root["export"] = export

        // 默认 teal 不写入配置；只有项目明确选过颜色时才保存色相。
        if let hue = ThemeConfig.normalizedAccentHue(cfg.theme.accentHue) {
            let theme = TOMLTable()
            theme["accent_hue"] = hue
            root["theme"] = theme
        }

        return root.convert()
    }

    static func save(_ cfg: AppConfig, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialize(cfg).write(to: path, atomically: true, encoding: .utf8)
    }
}

import Foundation
import TOMLKit

// litnexus.toml 的读写，对应 Python 参考的 config.py / config_saver.py。
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
        }

        if let a = table["ai"]?.tomlValue.table {
            cfg.ai.apiKey = a["api_key"]?.tomlValue.string ?? cfg.ai.apiKey
            cfg.ai.baseURL = a["base_url"]?.tomlValue.string ?? cfg.ai.baseURL
            cfg.ai.model = a["model"]?.tomlValue.string ?? cfg.ai.model
        }

        if let t = table["translate"]?.tomlValue.table {
            cfg.translate.batchSize = t["batch_size"]?.tomlValue.int ?? cfg.translate.batchSize
            cfg.translate.concurrency = t["concurrency"]?.tomlValue.int ?? cfg.translate.concurrency
        }

        if let c = table["classify"]?.tomlValue.table {
            cfg.classify.maxWorkers = c["max_workers"]?.tomlValue.int ?? cfg.classify.maxWorkers
            if let qs = c["questions"]?.tomlValue.array {
                var questions: [Question] = []
                for item in qs {
                    if let qt = item.tomlValue.table,
                       let id = qt["id"]?.tomlValue.string,
                       let text = qt["text"]?.tomlValue.string {
                        questions.append(Question(id: id, text: text))
                    }
                }
                cfg.classify.questions = questions
            }
        }

        if let s = table["schema"]?.tomlValue.table,
           let cols = s["custom_columns"]?.tomlValue.array {
            cfg.schema.customColumns = cols.compactMap { $0.tomlValue.string }
        }

        if let e = table["export"]?.tomlValue.table {
            cfg.export.filter = e["filter"]?.tomlValue.string ?? cfg.export.filter
            if let cols = e["exclude_columns"]?.tomlValue.array {
                cfg.export.excludeColumns = cols.compactMap { $0.tomlValue.string }
            }
        }

        return cfg
    }

    static func serialize(_ cfg: AppConfig) -> String {
        let root = TOMLTable()

        let download = TOMLTable()
        download["days"] = cfg.download.days
        download["page_size"] = cfg.download.pageSize
        download["request_delay"] = cfg.download.requestDelay
        root["download"] = download

        let ai = TOMLTable()
        ai["api_key"] = cfg.ai.apiKey
        ai["base_url"] = cfg.ai.baseURL
        ai["model"] = cfg.ai.model
        root["ai"] = ai

        let translate = TOMLTable()
        translate["batch_size"] = cfg.translate.batchSize
        translate["concurrency"] = cfg.translate.concurrency
        root["translate"] = translate

        let classify = TOMLTable()
        classify["max_workers"] = cfg.classify.maxWorkers
        let questions = TOMLArray()
        for q in cfg.classify.questions {
            let qt = TOMLTable()
            qt["id"] = q.id
            qt["text"] = q.text
            questions.append(qt)
        }
        classify["questions"] = questions
        root["classify"] = classify

        let schema = TOMLTable()
        let customCols = TOMLArray()
        for c in cfg.schema.customColumns { customCols.append(c) }
        schema["custom_columns"] = customCols
        root["schema"] = schema

        let export = TOMLTable()
        export["filter"] = cfg.export.filter
        let excl = TOMLArray()
        for c in cfg.export.excludeColumns { excl.append(c) }
        export["exclude_columns"] = excl
        root["export"] = export

        return root.convert()
    }

    static func save(_ cfg: AppConfig, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialize(cfg).write(to: path, atomically: true, encoding: .utf8)
    }
}

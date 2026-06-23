import Foundation

// 配置数据模型，1:1 对应 Python 参考实现 core/config.py 的 Pydantic 模型。
// 无默认值的 AI 接口要求用户自行填写（不内置任何服务商）。

struct DownloadConfig: Equatable {
    var days: Int = 30
    var pageSize: Int = 1000
    var requestDelay: Double = 0.5
    // 期刊与关键词检索式现统一存进配置（数组，每元素一行，含注释行）。下载时过滤 # 与空行。
    var journals: [String] = Templates.defaultJournalLines
    var keywords: [String] = Templates.defaultKeywordLines
}

struct AIConfig: Equatable {
    var apiKey: String = ""
    var baseURL: String = ""
    var model: String = ""
    /// 可选的额外请求参数（JSON 对象字符串），合并进每次请求体。
    /// 用于各家不统一的开关，如关推理：{"enable_thinking": false} 或 {"reasoning_effort": "minimal"}。
    var extraParams: String = ""
}

// 一个具名的 AI 配置方案。用户可保存多个，选其一作为当前使用。
struct AIProfile: Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = "新方案"
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""
    var extraParams: String = ""

    var asConfig: AIConfig { AIConfig(apiKey: apiKey, baseURL: baseURL, model: model, extraParams: extraParams) }
    var isComplete: Bool { !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        && !model.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct TranslateConfig: Equatable {
    var batchSize: Int = 30
    var concurrency: Int = 20
    var translateAbstract: Bool = true   // 是否默认翻译摘要（标题始终翻译）
    var abstractBatchSize: Int = 10       // 摘要较长，批量小一些避免超出上下文
}

// 一个分类问题。id 在创建时自动分配、永不复用、对用户隐藏；
// nickname 是用户起的短标签（导出表头用它）；classify/export 为两个独立开关。
struct Question: Identifiable, Hashable {
    var id: String
    var nickname: String = ""
    var text: String
    var classify: Bool = true   // 是否让 AI 处理（关掉=停用，但保留列与数据）
    var export: Bool = true     // 导出 CSV 时是否包含这两列

    var displayName: String { nickname.trimmingCharacters(in: .whitespaces).isEmpty ? id : nickname }
}

struct ClassifyConfig: Equatable {
    var maxWorkers: Int = 20    // 并发的「批」数量（每批一次 API 调用）
    var batchSize: Int = 15     // 每次 API 调用合并多少篇文章（受输出 token 上限与准确率约束，别过大）
    var maxAttempts: Int = 3    // 同一批/篇解析失败重试上限，超过则标记为「失败」、不再无限重试
    var questions: [Question] = Templates.defaultQuestions

    /// 下一个永不复用的问题 id：取所有现存 q<N> 的最大 N + 1（含已停用问题）。
    func nextQuestionID() -> String {
        let maxN = questions.compactMap { q -> Int? in
            guard q.id.hasPrefix("q"), let n = Int(q.id.dropFirst()) else { return nil }
            return n
        }.max() ?? 0
        return "q\(maxN + 1)"
    }
}

struct SchemaConfig: Equatable {
    var customColumns: [String] = ["include", "tags"]
}

struct ExportConfig: Equatable {
    var filter: String = "pending"
    // 默认仅排除两个体积大、人不读的 JSON 列；摘要译文等默认导出。可在「导出列」界面调整。
    var excludeColumns: [String] = ["journal_info_json", "keyword_list_json"]
}

struct AppConfig: Equatable {
    var download = DownloadConfig()
    var aiProfiles: [AIProfile] = []
    var activeAIID: String = ""
    var translate = TranslateConfig()
    var classify = ClassifyConfig()
    var schema = SchemaConfig()
    var export = ExportConfig()

    var activeProfile: AIProfile? { aiProfiles.first(where: { $0.id == activeAIID }) ?? aiProfiles.first }
    var ai: AIConfig { activeProfile?.asConfig ?? AIConfig() }
}

// 合法 SQL 标识符（列名 / 列前缀），防止拼进 SQL 出错或注入。
enum Identifier {
    static func isValid(_ s: String) -> Bool {
        let pattern = "^[A-Za-z_][A-Za-z0-9_]*$"
        return s.range(of: pattern, options: .regularExpression) != nil
    }
}

// 运行期解析环境变量覆盖后的有效 AI 配置（不写回磁盘，避免密钥落盘）。
extension AppConfig {
    // 桌面应用：完全以界面所选 AI 方案为准，不读取任何环境变量
    // （避免旧环境变量悄悄顶替用户输入，这类行为在桌面端是反直觉的）。
    var resolvedAI: AIConfig { ai }
    var hasAPIKey: Bool { !ai.apiKey.isEmpty }
}

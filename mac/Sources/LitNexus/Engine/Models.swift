import Foundation

// 配置数据模型，1:1 对应 Python 参考实现 core/config.py 的 Pydantic 模型。
// 无默认值的 AI 接口要求用户自行填写（不内置任何服务商）。

struct DownloadConfig: Equatable {
    var days: Int = 30
    var pageSize: Int = 1000
    var requestDelay: Double = 0.5
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
}

struct Question: Identifiable, Hashable {
    var id: String
    var text: String
}

struct ClassifyConfig: Equatable {
    var maxWorkers: Int = 100
    var questions: [Question] = Templates.defaultQuestions
}

struct SchemaConfig: Equatable {
    var customColumns: [String] = ["include", "tags"]
}

struct ExportConfig: Equatable {
    var filter: String = "pending"
    var excludeColumns: [String] = ["journal_info_json", "keyword_list_json", "abstract_zh"]
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

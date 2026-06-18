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
    var ai = AIConfig()
    var translate = TranslateConfig()
    var classify = ClassifyConfig()
    var schema = SchemaConfig()
    var export = ExportConfig()
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
    var resolvedAI: AIConfig {
        let env = ProcessInfo.processInfo.environment
        var out = ai
        out.apiKey = env["LITNEXUS_API_KEY"] ?? env["ARK_API_KEY"] ?? ai.apiKey
        out.baseURL = env["LITNEXUS_BASE_URL"] ?? env["ARK_API_BASE_URL"] ?? ai.baseURL
        return out
    }

    var hasAPIKey: Bool {
        let env = ProcessInfo.processInfo.environment
        return !(env["LITNEXUS_API_KEY"] ?? env["ARK_API_KEY"] ?? ai.apiKey).isEmpty
    }
}

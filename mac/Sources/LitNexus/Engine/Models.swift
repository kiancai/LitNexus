import Foundation

// 应用与工作区配置的数据模型。
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

/// 新问题在什么范围内等待 AI 回答。
///
/// `futureArticles` 不是按发布日期判断，而是在创建问题时记录数据库的 rowid 前沿；
/// 因而“未来”精确指随后真正合并入当前项目的新文章，不会因为文章发表年份较早而漏掉。
enum QuestionCoverage: String, CaseIterable, Identifiable {
    case allArticles
    case futureArticles

    var id: String { rawValue }

    var label: String {
        switch self {
        case .futureArticles: return "仅以后新文章"
        case .allArticles: return "全部已有与未来文章"
        }
    }

    var shortLabel: String {
        switch self {
        case .futureArticles: return "仅未来"
        case .allArticles: return "全部文章"
        }
    }

    var explanation: String {
        switch self {
        case .futureArticles:
            return "创建后新合并入库的文章才会等待此问题的 AI 分类；不会产生历史补答费用。"
        case .allArticles:
            return "当前库中尚未回答的文章和以后新文章都会等待此问题的 AI 分类；下一次运行可能消耗较多 AI 额度。"
        }
    }
}

// 一个分类问题。id 在创建时自动分配、永不复用、对用户隐藏；
// nickname 是用户起的短标签（导出表头用它）；classify/export 为两个独立开关。
//
// `archived` 和 `classify` 必须分开：归档只是让问题退出未来的流水线，
// 不等于用户原本关闭了「AI 处理」。恢复归档后仍保留用户此前的开关选择。
struct Question: Identifiable, Hashable {
    var id: String
    var nickname: String = ""
    var text: String
    var classify: Bool = true   // 是否让 AI 处理（关掉=停用，但保留列与数据）
    var export: Bool = true     // 导出 CSV 时是否包含这两列
    /// 已归档的问题不再参与未来分类与默认统计，但历史答案仍保留在数据库里。
    var archived: Bool = false
    /// nil 表示历史与未来文章都适用；非空时只处理 rowid 大于该前沿的后续入库文章。
    /// 这是对当前动态列架构的兼容性过渡，未来会迁移为可审计的问题版本／运行记录。
    var classifyAfterRowID: Int? = nil

    var displayName: String { nickname.trimmingCharacters(in: .whitespaces).isEmpty ? id : nickname }

    /// 面向流水线的有效开关。不要只检查 `classify`，否则归档问题会被重新送进 AI。
    var isActiveForClassification: Bool { classify && !archived }

    /// 面向默认统计／导出的可见性。历史数据仍可由“显示归档项目”的界面入口读取。
    var isCurrent: Bool { !archived }

    var coverage: QuestionCoverage { classifyAfterRowID == nil ? .allArticles : .futureArticles }
    var appliesToHistoricalArticles: Bool { classifyAfterRowID == nil }

    /// 用于将拥有同一适用范围的问题放进同一个 AI 批次；不同前沿不能混批，
    /// 否则会把“仅未来”的问题错误地提问给历史文章。
    var classificationScopeKey: Int? { classifyAfterRowID }
}

struct ClassifyConfig: Equatable {
    var maxWorkers: Int = 20    // 并发的「批」数量（每批一次 API 调用）
    var batchSize: Int = 15     // 每次 API 调用合并多少篇文章（受输出 token 上限与准确率约束，别过大）
    var maxAttempts: Int = 3    // 同一批/篇解析失败重试上限，超过则标记为「失败」、不再无限重试
    var questions: [Question] = Templates.defaultQuestions
    /// 下一个可分配的 `q<N>` 数字。它是高水位而非“当前问题数”，因此即使永久删除
    /// 问题，也绝不会复用旧 id。旧项目未保存该字段时从现存 id 推断并在下次保存时写入。
    var nextQuestionNumber: Int = 3

    /// 兼容只读调用的“下一个候选 id”。真正创建问题必须调用 `allocateQuestionID()`，
    /// 才会推进持久化的高水位。
    func nextQuestionID() -> String {
        "q\(normalizedNextQuestionNumber)"
    }

    /// 供 TOML 写入使用的已校正高水位。
    var persistedNextQuestionNumber: Int { normalizedNextQuestionNumber }

    /// 分配一个新的、永不复用的问题 id，并立即推进高水位；调用方必须随后持久化 config。
    mutating func allocateQuestionID() -> String {
        let next = normalizedNextQuestionNumber
        nextQuestionNumber = next + 1
        return "q\(next)"
    }

    /// 在读取旧 TOML、手动编辑 TOML 或合并配置后调用，防止高水位落在现有 id 之前。
    mutating func normalizeQuestionIDAllocator() {
        nextQuestionNumber = normalizedNextQuestionNumber
    }

    private var normalizedNextQuestionNumber: Int {
        let maxExisting = questions.compactMap { q -> Int? in
            guard q.id.hasPrefix("q"), let n = Int(q.id.dropFirst()), n >= 1 else { return nil }
            return n
        }.max() ?? 0
        return max(1, nextQuestionNumber, maxExisting + 1)
    }
}

struct SchemaConfig: Equatable {
    var customColumns: [String] = ["include", "tags"]

    /// 人工复筛的两列是稳定的项目合同，不能通过配置页误删。
    static let requiredReviewColumns = ["include", "tags"]

    /// 自定义标注列不能伪装成文章事实列或 AI 问题列，否则 CSV 回写的边界会变得模糊。
    static func normalizedAnnotationColumns(_ values: [String]) -> [String] {
        let reserved: Set<String> = [
            "epmc_id", "pmid", "doi", "source", "pmcid", "title", "abstract", "pub_year",
            "author_string", "journal_title", "first_publication_date", "query_search_term",
            "journal_info_json", "keyword_list_json", "title_zh", "abstract_zh",
        ]
        var seen = Set<String>()
        var result = requiredReviewColumns
        seen.formUnion(result)
        for value in values {
            let column = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Identifier.isValid(column),
                  !reserved.contains(column),
                  !column.hasSuffix("_ans"),
                  !column.hasSuffix("_rea"),
                  seen.insert(column).inserted else { continue }
            result.append(column)
        }
        return result
    }
}

struct ExportConfig: Equatable {
    var filter: String = "pending"
    // 默认仅排除两个体积大、人不读的 JSON 列；摘要译文等默认导出。可在「导出列」界面调整。
    var excludeColumns: [String] = ["journal_info_json", "keyword_list_json"]
}

/// 项目视觉配置。外观模式属于当前设备偏好，主题色则随工作区同步。
struct ThemeConfig: Equatable {
    /// `nil` 表示使用 LitNexus 默认 teal；自定义时只持久化色相，界面自行推导明暗与层级色。
    var accentHue: Double? = nil

    /// 只接受色盘产生的标准 HSB 色相。`1` 与 `0` 是同一色相，统一写为 `0`。
    static func normalizedAccentHue(_ hue: Double?) -> Double? {
        guard let hue, hue.isFinite, (0 ... 1).contains(hue) else { return nil }
        return hue == 1 ? 0 : hue
    }
}

struct AppConfig: Equatable {
    var download = DownloadConfig()
    var aiProfiles: [AIProfile] = []
    var activeAIID: String = ""
    var translate = TranslateConfig()
    var classify = ClassifyConfig()
    var schema = SchemaConfig()
    var export = ExportConfig()
    var theme = ThemeConfig()

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

// 桌面端运行时使用的有效 AI 配置。
extension AppConfig {
    // 桌面应用：完全以界面所选 AI 方案为准，不读取任何环境变量
    // （避免旧环境变量悄悄顶替用户输入，这类行为在桌面端是反直觉的）。
    var resolvedAI: AIConfig { ai }
}

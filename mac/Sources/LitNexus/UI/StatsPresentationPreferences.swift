import Foundation

/// 可重排的统计卡片。总览是固定锚点，不属于这个列表。
enum StatsCardID: String, CaseIterable, Identifiable {
    case years
    case journals
    case promptDistribution
    case promptAgreement
    case promptKeywords
    case journalRecommendations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .years: return "年代分布"
        case .journals: return "期刊分布"
        case .promptDistribution: return "提示词评估 · 分类结果分布"
        case .promptAgreement: return "提示词评估 · 人工复筛对照"
        case .promptKeywords: return "提示词评估 · 检索词产出"
        case .journalRecommendations: return "期刊策略 · 期刊清单观察"
        }
    }

    var symbol: String {
        switch self {
        case .years: return "chart.bar.xaxis"
        case .journals: return "building.2"
        case .promptDistribution: return "text.bubble"
        case .promptAgreement: return "checklist"
        case .promptKeywords: return "magnifyingglass"
        case .journalRecommendations: return "list.bullet.clipboard"
        }
    }

    static let defaultOrder: [StatsCardID] = [
        .years,
        .journals,
        .promptDistribution,
        .promptAgreement,
        .promptKeywords,
        .journalRecommendations,
    ]

    static let defaultExpanded: Set<StatsCardID> = [.years, .journals]
}

/// 统计页是个人工作台布局：排序与折叠状态属于当前设备的界面偏好，
/// 不写进项目 TOML，也不会跟着项目数据导入导出。
struct StatsPresentationPreferences {
    private static let orderKey = "stats.presentation.order.v1"
    private static let expandedKey = "stats.presentation.expanded.v1"

    private let defaults: UserDefaults
    private(set) var order: [StatsCardID]
    private(set) var expanded: Set<StatsCardID>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedOrder = defaults.stringArray(forKey: Self.orderKey) ?? []
        var seen = Set<StatsCardID>()
        var resolvedOrder = storedOrder.compactMap(StatsCardID.init(rawValue:)).filter { seen.insert($0).inserted }
        resolvedOrder.append(contentsOf: StatsCardID.defaultOrder.filter { !seen.contains($0) })
        order = resolvedOrder

        if let storedExpanded = defaults.stringArray(forKey: Self.expandedKey) {
            expanded = Set(storedExpanded.compactMap(StatsCardID.init(rawValue:)))
        } else {
            expanded = StatsCardID.defaultExpanded
        }
    }

    func isExpanded(_ card: StatsCardID) -> Bool { expanded.contains(card) }

    mutating func setExpanded(_ isExpanded: Bool, for card: StatsCardID) {
        if isExpanded { expanded.insert(card) }
        else { expanded.remove(card) }
        persist()
    }

    mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    mutating func replaceOrder(_ next: [StatsCardID]) {
        var seen = Set<StatsCardID>()
        var resolved = next.filter { seen.insert($0).inserted }
        resolved.append(contentsOf: StatsCardID.defaultOrder.filter { !seen.contains($0) })
        order = resolved
    }

    mutating func persist() {
        defaults.set(order.map(\.rawValue), forKey: Self.orderKey)
        defaults.set(expanded.map(\.rawValue).sorted(), forKey: Self.expandedKey)
    }
}

import SwiftUI
import Charts
import UniformTypeIdentifiers

/// 统计页把「项目事实」和「策略判断」分开：总览固定，其他卡片可由用户折叠和排序。
struct StatsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accentPalette) private var palette

    @State private var bundle: StatsBundle?
    @State private var isInitialLoading = true
    @State private var isRefreshing = false
    @State private var isLoadingStats = false
    @State private var dimColumn = "include"
    @State private var yearScale: YearScale = .logarithmic
    @State private var journalSort: JournalSort = .total
    @State private var journalSortAscending = false
    @State private var journalQuery = ""
    @State private var presentation = StatsPresentationPreferences()
    @State private var isEditingLayout = false
    @State private var layoutWiggle = false
    @State private var editingOrder: [StatsCardID] = []
    @State private var draggingCard: StatsCardID?
    @State private var loadingInsights: Set<StatsInsight> = []

    var body: some View {
        PageContainer {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader

                if let bundle {
                    overviewCard(bundle)

                    if (bundle.overview["total"] ?? 0) > 0 {
                        orderedCards(bundle)
                    } else {
                        emptyDatabaseCard
                    }
                } else if isInitialLoading {
                    loadingSkeleton
                } else {
                    unavailableCard
                }
            }
        }
        .onAppear {
            if bundle == nil { load() }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            PageHeader(title: "统计", guide: PageGuides.stats, symbol: Page.stats.symbol)
            Spacer(minLength: 12)

            if isEditingLayout {
                Button(action: finishLayoutEditing) {
                    Label("保存布局", systemImage: "checkmark")
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("保存卡片顺序，并恢复编辑前的展开状态")
            } else {
                Button { load(force: true) } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small).frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .disabled(isInitialLoading || isRefreshing)
                .help("刷新统计")

                Button(action: beginLayoutEditing) {
                    Label("编辑", systemImage: "pencil")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.control.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.line.opacity(0.9), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.fg)
                .disabled(isInitialLoading)
                .help("调整总览以下卡片的顺序")
            }
        }
    }

    private func load(force: Bool = false) {
        guard !isLoadingStats else { return }
        if force {
            loadingInsights = []
            app.invalidateStatsCache()
        }
        isLoadingStats = true
        let retainsCurrentContent = bundle != nil
        if retainsCurrentContent { isRefreshing = true }
        else { isInitialLoading = true }

        app.computeStats { next in
            bundle = next
            if let next, !next.dimensions.contains(where: { $0.column == dimColumn }) {
                dimColumn = next.dimensions.first?.column ?? "include"
            }
            loadPersistedExpandedInsights()
            isInitialLoading = false
            isRefreshing = false
            isLoadingStats = false
        }
    }

    // MARK: - Fixed overview

    private func overviewCard(_ bundle: StatsBundle) -> some View {
        Card {
            SectionTitle("总览")
            MetricsRow(items: [
                (value: bundle.overview["total"] ?? 0, label: "总文章数", color: palette.accent),
                (value: bundle.overview["reviewed_pending"] ?? 0, label: "待复筛", color: Theme.amber),
                (value: bundle.overview["reviewed_yes"] ?? 0, label: "纳入", color: Theme.green),
                (value: bundle.overview["reviewed_no"] ?? 0, label: "排除", color: Theme.muted),
            ])
        }
    }

    private var emptyDatabaseCard: some View {
        Card {
            Text("数据库为空——先到「运行」下载并合并文献。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
    }

    private var unavailableCard: some View {
        Card {
            Text("暂时无法读取统计。请确认项目数据库仍可访问后再刷新。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
    }

    // MARK: - User ordered cards

    @ViewBuilder private func orderedCards(_ bundle: StatsBundle) -> some View {
        let cards = isEditingLayout ? editingOrder : presentation.order
        ForEach(cards) { card in
            editableStatisticsCard(card, bundle: bundle)
        }
    }

    @ViewBuilder private func editableStatisticsCard(_ card: StatsCardID, bundle: StatsBundle) -> some View {
        if isEditingLayout {
            statisticsCard(card, forceCollapsed: true, reordering: true) {
                EmptyView()
            }
            .rotationEffect(.degrees(wiggleAngle(for: card)))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .onDrag {
                draggingCard = card
                return NSItemProvider(object: card.rawValue as NSString)
            }
            .onDrop(of: [UTType.text], delegate: StatsCardDropDelegate(
                target: card,
                order: $editingOrder,
                dragging: $draggingCard
            ))
        } else {
            statisticsCard(card) {
                cardContent(card, bundle: bundle)
            }
        }
    }

    private func statisticsCard<Content: View>(
        _ card: StatsCardID,
        forceCollapsed: Bool = false,
        reordering: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = !forceCollapsed && presentation.isExpanded(card)

        return Card {
            HStack(spacing: 8) {
                Button {
                    guard !reordering else { return }
                    setExpanded(!expanded, for: card)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: card.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(expanded ? palette.accent : Theme.muted)
                            .frame(width: 18)

                        Text(card.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.fg)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(reordering)

                if !reordering, let help = cardHelp(card) {
                    StatsInfoButton(title: card.title, text: help)
                }

                Spacer(minLength: 12)

                if reordering {
                    Text("拖动排序")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.muted)
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.accent)
                } else {
                    Button {
                        setExpanded(!expanded, for: card)
                    } label: {
                        HStack(spacing: 6) {
                            Text(expanded ? "收起" : "展开")
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .foregroundStyle(Theme.muted)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }

            if expanded {
                Divider().overlay(Theme.line)
                content()
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: expanded)
    }

    @ViewBuilder private func cardContent(_ card: StatsCardID, bundle: StatsBundle) -> some View {
        switch card {
        case .years:
            yearsContent(bundle)
        case .journals:
            journalsContent(bundle)
        case .promptDistribution:
            insightContent(.promptDistribution, bundle: bundle) {
                promptDistributionContent(bundle)
            }
        case .promptAgreement:
            insightContent(.promptAgreement, bundle: bundle) {
                promptAgreementContent(bundle)
            }
        case .promptKeywords:
            insightContent(.keywordTerms, bundle: bundle) {
                promptKeywordsContent(bundle)
            }
        case .journalRecommendations:
            insightContent(.journalObservations, bundle: bundle) {
                journalRecommendationsContent(bundle)
            }
        }
    }

    @ViewBuilder private func insightContent<Content: View>(
        _ insight: StatsInsight,
        bundle: StatsBundle,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if bundle.hasLoaded(insight) {
            content()
        } else {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("正在读取…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 8)
        }
    }

    private func beginLayoutEditing() {
        editingOrder = presentation.order
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditingLayout = true
        }
        DispatchQueue.main.async {
            guard isEditingLayout else { return }
            withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) {
                layoutWiggle = true
            }
        }
    }

    private func finishLayoutEditing() {
        var revised = presentation
        revised.replaceOrder(editingOrder)
        revised.persist()
        presentation = revised
        draggingCard = nil
        layoutWiggle = false
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditingLayout = false
        }
    }

    private func wiggleAngle(for card: StatsCardID) -> Double {
        guard layoutWiggle else { return 0 }
        let index = editingOrder.firstIndex(of: card) ?? 0
        return index.isMultiple(of: 2) ? 0.55 : -0.55
    }

    private func setExpanded(_ value: Bool, for card: StatsCardID) {
        var revised = presentation
        revised.setExpanded(value, for: card)
        presentation = revised
        if value, let insight = insight(for: card) {
            loadInsightIfNeeded(insight)
        }
    }

    private func insight(for card: StatsCardID) -> StatsInsight? {
        switch card {
        case .promptDistribution: return .promptDistribution
        case .promptAgreement: return .promptAgreement
        case .promptKeywords: return .keywordTerms
        case .journalRecommendations: return .journalObservations
        case .years, .journals: return nil
        }
    }

    private func loadInsightIfNeeded(_ insight: StatsInsight) {
        guard let bundle, !bundle.hasLoaded(insight), !loadingInsights.contains(insight) else { return }
        loadingInsights.insert(insight)
        app.loadStatsInsights([insight]) { next in
            if let next { self.bundle = next }
            loadingInsights.remove(insight)
        }
    }

    private func loadPersistedExpandedInsights() {
        for card in presentation.order where presentation.isExpanded(card) {
            if let insight = insight(for: card) {
                loadInsightIfNeeded(insight)
            }
        }
    }

    private func cardHelp(_ card: StatsCardID) -> String? {
        switch card {
        case .promptDistribution:
            return "若某问题“是”的比例过高，它可能没有形成有效筛选；比例过低则可能过于严格。请结合人工复筛和研究目标判断，不以单一比例自动判定好坏。"
        case .promptAgreement:
            return "这里将 AI 的各问题回答与人工最终复筛并列展示。宽泛或保守的提示词都可能是合理选择，因此使用中性描述而非“对错”。"
        case .journalRecommendations:
            return "该卡片只呈现当前期刊清单与人工复筛样本之间的事实关系，不会替你决定加入、删除或修改期刊列表。"
        default:
            return nil
        }
    }

    // MARK: - 基础分布：年代

    private func yearsContent(_ bundle: StatsBundle) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                if bundle.dimensions.count > 1 {
                    Picker("显示维度", selection: $dimColumn) {
                        ForEach(bundle.dimensions) { item in
                            Text(item.label).tag(item.column)
                        }
                    }
                    .frame(width: 220)
                }

                Spacer(minLength: 8)

                Picker("刻度", selection: $yearScale) {
                    ForEach(YearScale.allCases) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 118)
                .help("对数刻度会让少量纳入文章在图中仍然可见")
            }

            let segments = yearSegments(bundle)
            if segments.isEmpty {
                Text("无带年份的数据。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                yearChart(segments, isReview: dimColumn == "include")

                if yearScale == .logarithmic {
                    Text("柱高按 log₁₀(文章数 + 1) 转换，使少量纳入文章可见；切换为“线性”可查看绝对量级。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
            }

            if !bundle.sources.isEmpty {
                Divider().overlay(Theme.line)
                HStack(spacing: 5) {
                    Text("来源构成")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.fg)
                    StatsInfoButton(title: "来源代码", text: SourceCodeHelp.text)
                }
                ProportionBar(segments: bundle.sources.map { value, count in
                    (label: sourceLabel(value), count: count, color: sourceColor(value))
                })
            }
        }
    }

    private struct YearSegment: Identifiable {
        let year: Int
        let category: String
        let count: Int
        var id: String { "\(year)-\(category)" }
    }

    private func yearSegments(_ bundle: StatsBundle) -> [YearSegment] {
        guard let raw = bundle.yearRaw[dimColumn] else { return [] }
        let isReview = dimColumn == "include"
        var aggregated: [Int: [String: Int]] = [:]

        for (year, value, count) in raw {
            let category: String
            if isReview {
                switch value {
                case "yes": category = "纳入"
                case "no": category = "排除"
                default: category = "待复筛"
                }
            } else {
                switch value {
                case "是": category = "是"
                case "否": category = "否"
                default: category = "未分类"
                }
            }
            aggregated[year, default: [:]][category, default: 0] += count
        }

        let order = isReview ? ["纳入", "排除", "待复筛"] : ["是", "否", "未分类"]
        return aggregated.keys.sorted().flatMap { year in
            order.compactMap { category in
                guard let count = aggregated[year]?[category], count > 0 else { return nil }
                return YearSegment(year: year, category: category, count: count)
            }
        }
    }

    private func plottedYearValue(_ count: Int) -> Double {
        guard yearScale == .logarithmic else { return Double(count) }
        return log10(Double(count) + 1)
    }

    @ViewBuilder private func yearChart(_ segments: [YearSegment], isReview: Bool) -> some View {
        if isReview {
            Chart(segments) { segment in
                yearBar(segment)
            }
            .chartForegroundStyleScale([
                "纳入": Theme.green,
                "排除": Theme.muted.opacity(0.62),
                "待复筛": Theme.line,
            ])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 250)
        } else {
            Chart(segments) { segment in
                yearBar(segment)
            }
            .chartForegroundStyleScale([
                "是": Theme.green,
                "否": Theme.muted.opacity(0.62),
                "未分类": Theme.line,
            ])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 250)
        }
    }

    private func yearBar(_ segment: YearSegment) -> some ChartContent {
        BarMark(
            x: .value("年份", String(segment.year)),
            // BarMark 默认从 0 作为基线；原生 `.log` 轴无法表示该基线，
            // 因此对数模式采用安全的 log₁₀(n + 1) 显示值。
            y: .value("数量", plottedYearValue(segment.count))
        )
        .foregroundStyle(by: .value("类别", segment.category))
    }

    private func sourceLabel(_ value: String?) -> String {
        switch value {
        case "MED": return "MED"
        case "PMC": return "PMC"
        case "PPR": return "PPR"
        case .some(let source) where !source.isEmpty: return source
        default: return "未知"
        }
    }

    private func sourceColor(_ value: String?) -> Color {
        switch value {
        case "MED": return palette.accent
        case "PPR": return Theme.amber
        default: return Theme.muted
        }
    }

    // MARK: - 基础分布：全部期刊

    private func journalsContent(_ bundle: StatsBundle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("完整期刊集合：\(visibleJournals(bundle).count) / \(bundle.journals.count) 个")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }

            TextField("搜索期刊", text: $journalQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            journalTableHeader

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleJournals(bundle)) { journal in
                        journalRow(journal)
                        Divider().overlay(Theme.line.opacity(0.74))
                    }
                }
            }
            .frame(height: 380)
            .background(Theme.panel2.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var journalTableHeader: some View {
        HStack(spacing: 8) {
            journalHeader("期刊", column: .journal, nameColumn: true)
            journalHeader("收录", column: .total, width: JournalColumns.total)
            journalHeader("待复筛", column: .pending, width: JournalColumns.pending)
            journalHeader("纳入", column: .included, width: JournalColumns.included)
            journalHeader("排除", column: .excluded, width: JournalColumns.excluded)
            journalHeader("入选率", column: .rate, width: JournalColumns.rate)
        }
        .padding(.horizontal, JournalColumns.horizontalInset)
        .padding(.bottom, 2)
    }

    @ViewBuilder private func journalHeader(
        _ title: String,
        column: JournalSort,
        width: CGFloat? = nil,
        nameColumn: Bool = false
    ) -> some View {
        Button { toggleJournalSort(column) } label: {
            HStack(spacing: 3) {
                Text(title)
                if journalSort == column {
                    Image(systemName: journalSortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(journalSort == column ? palette.accent : Theme.muted)
            .frame(
                minWidth: nameColumn ? JournalColumns.nameMinimum : nil,
                maxWidth: nameColumn ? .infinity : nil,
                alignment: nameColumn ? .leading : .trailing
            )
            .frame(width: width, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("按\(title)排序")
    }

    private func journalRow(_ journal: JournalStat) -> some View {
        let pending = max(0, journal.total - journal.reviewed)
        return HStack(spacing: 8) {
            Text(journal.journal)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.fg)
                .lineLimit(1)
                .help(journal.journal)
                .frame(minWidth: JournalColumns.nameMinimum, maxWidth: .infinity, alignment: .leading)
            Text(journal.total.formatted())
                .frame(width: JournalColumns.total, alignment: .trailing)
            Text(pending.formatted())
                .frame(width: JournalColumns.pending, alignment: .trailing)
                .foregroundStyle(Theme.muted)
            Text(journal.included.formatted())
                .frame(width: JournalColumns.included, alignment: .trailing)
                .foregroundStyle(Theme.green)
            Text(journal.excluded.formatted())
                .frame(width: JournalColumns.excluded, alignment: .trailing)
                .foregroundStyle(Theme.muted)
            Text(journal.reviewed > 0 ? "\(Int((journal.rate * 100).rounded()))%" : "—")
                .frame(width: JournalColumns.rate, alignment: .trailing)
                .foregroundStyle(journal.reviewed > 0 ? rateColor(journal.rate) : Theme.muted)
        }
        .font(.system(size: 12))
        .padding(.horizontal, JournalColumns.horizontalInset)
        .padding(.vertical, 7)
    }

    private func visibleJournals(_ bundle: StatsBundle) -> [JournalStat] {
        let needle = journalQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = bundle.journals.filter { needle.isEmpty || $0.journal.lowercased().contains(needle) }
        return matches.sorted { left, right in
            let direction: ComparisonResult
            switch journalSort {
            case .journal:
                direction = left.journal.localizedCaseInsensitiveCompare(right.journal)
            case .total:
                direction = left.total == right.total ? .orderedSame : (left.total < right.total ? .orderedAscending : .orderedDescending)
            case .pending:
                let l = left.total - left.reviewed
                let r = right.total - right.reviewed
                direction = l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
            case .included:
                direction = left.included == right.included ? .orderedSame : (left.included < right.included ? .orderedAscending : .orderedDescending)
            case .excluded:
                direction = left.excluded == right.excluded ? .orderedSame : (left.excluded < right.excluded ? .orderedAscending : .orderedDescending)
            case .rate:
                // 未复筛的期刊没有入选率；无论升降都排在有数据的期刊之后。
                if left.reviewed == 0 || right.reviewed == 0 {
                    if left.reviewed == 0 && right.reviewed == 0 { direction = .orderedSame }
                    else { return right.reviewed == 0 }
                } else {
                    direction = left.rate == right.rate ? .orderedSame : (left.rate < right.rate ? .orderedAscending : .orderedDescending)
                }
            }
            if direction == .orderedSame {
                return left.journal.localizedCaseInsensitiveCompare(right.journal) == .orderedAscending
            }
            return journalSortAscending ? direction == .orderedAscending : direction == .orderedDescending
        }
    }

    private func toggleJournalSort(_ column: JournalSort) {
        if journalSort == column {
            journalSortAscending.toggle()
        } else {
            journalSort = column
            journalSortAscending = column == .journal
        }
    }

    private func rateColor(_ rate: Double) -> Color {
        rate >= 0.5 ? Theme.green : (rate >= 0.2 ? Theme.amber : Theme.muted)
    }

    // MARK: - 高级卡片：提示词评估

    private func promptDistributionContent(_ bundle: StatsBundle) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if bundle.questions.isEmpty {
                Text("尚无分类问题。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                ForEach(bundle.questions, id: \.question.id) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.question.displayName)
                            .font(.system(size: 14, weight: .medium))
                        ProportionBar(segments: [
                            (label: "是", count: item.yes, color: Theme.green),
                            (label: "否", count: item.no, color: Theme.muted.opacity(0.6)),
                            (label: "N/A", count: item.na, color: Theme.amber),
                            (label: "未分类", count: item.pending, color: Theme.line),
                        ])
                    }
                }
            }
        }
    }

    private func promptAgreementContent(_ bundle: StatsBundle) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let combined = bundle.promptCombinedEvaluation
            if bundle.agreements.isEmpty && combined.humanIncludedButAnyAIDenied.isEmpty && combined.humanExcludedButAllAIApproved.isEmpty {
                Text("尚无可对照的数据。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                combinedPromptEvaluation(combined)

                ForEach(bundle.agreements, id: \.question.id) { agreement in
                    agreementRow(agreement)
                }
            }
        }
    }

    @ViewBuilder private func combinedPromptEvaluation(_ evaluation: PromptCombinedEvaluation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("综合回看")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 10) {
                promptEvaluationMetric(
                    label: "人工补入",
                    detail: "人工纳入，但至少一项 AI 判否",
                    count: evaluation.humanIncludedButAnyAIDenied.count,
                    color: Theme.amber
                )
                promptEvaluationMetric(
                    label: "共同推荐后人工排除",
                    detail: "所有问题均判是，但人工最终排除",
                    count: evaluation.humanExcludedButAllAIApproved.count,
                    color: Theme.red
                )
            }

            if !evaluation.humanIncludedButAnyAIDenied.isEmpty {
                Expander("全部人工补入记录 · \(evaluation.humanIncludedButAnyAIDenied.count)") {
                    promptEvaluationList(evaluation.humanIncludedButAnyAIDenied)
                }
            }

            if !evaluation.humanExcludedButAllAIApproved.isEmpty {
                HStack(spacing: 10) {
                    Text("共同推荐后人工排除")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 8)
                    Button {
                        app.exportAllQuestionsApprovedButExcluded()
                    } label: {
                        Label("导出 CSV", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("导出所有问题均判是、但人工最终排除的完整文章与理由")
                }
                Expander("查看全部记录 · \(evaluation.humanExcludedButAllAIApproved.count)") {
                    promptEvaluationList(evaluation.humanExcludedButAllAIApproved)
                }
            }
        }
        .padding(12)
        .background(Theme.panel2.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func promptEvaluationMetric(
        label: String,
        detail: String,
        count: Int,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count.formatted())
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.fg)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func promptEvaluationList(_ records: [PromptEvaluationRecord]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.titleZh?.isEmpty == false ? record.titleZh! : (record.title ?? record.epmcID))
                            .font(.system(size: 12, weight: .medium))
                        HStack(spacing: 7) {
                            if let journal = record.journal, !journal.isEmpty { Text(journal) }
                            if let year = record.publicationYear { Text(year.formatted()) }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)

                        let answers = record.answers.map { answer in
                            "\(answer.questionName)：\(answer.answer ?? "未回答")"
                        }.joined(separator: " · ")
                        Text(answers)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 9)
                    Divider().overlay(Theme.line.opacity(0.72))
                }
            }
        }
        .frame(maxHeight: 280)
    }

    @ViewBuilder private func agreementRow(_ agreement: QAgreement) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(agreement.question.displayName)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Text("同向 \(Int((agreement.agreeRate * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            ProportionBar(segments: [
                (label: "共同纳入", count: agreement.tp, color: Theme.green),
                (label: "共同排除", count: agreement.tn, color: Theme.muted.opacity(0.6)),
                (label: "人工补入", count: agreement.fn, color: Theme.amber),
                (label: "人工排除", count: agreement.fp, color: Theme.red),
            ])

            if !agreement.falseNeg.isEmpty {
                Expander("全部人工补入记录 · \(agreement.fn)") {
                    exampleList(agreement.falseNeg)
                }
            }
            if !agreement.falsePos.isEmpty {
                Expander("全部人工排除记录 · \(agreement.fp)") {
                    exampleList(agreement.falsePos)
                }
            }
        }
    }

    private func exampleList(_ examples: [(title: String, reason: String)]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(example.title)
                            .font(.system(size: 12, weight: .medium))
                        if !example.reason.isEmpty {
                            Text(example.reason)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private func promptKeywordsContent(_ bundle: StatsBundle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("全部检索词")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 12)
                StatsInfoButton(title: "重建检索渠道", text: "它会扫描项目中已下载并合并的原始文件，重新建立“文章来自哪条检索词”的对应关系。不会重新下载文献，也不会修改文章或人工复筛结果。")
                Button {
                    app.rebuildChannelMap { load() }
                } label: {
                    if app.rebuildingChannels {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(bundle.channelMapBuilt ? "重建来源对应" : "建立来源对应")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(app.rebuildingChannels)
                .help("扫描已下载文件重建检索渠道数据，无需重新下载")
            }

            if !bundle.channelMapBuilt {
                Text("尚未建立检索渠道数据。可从已下载文件重建，不会重新下载文献。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else if bundle.keywordTerms.isEmpty {
                Text("暂无关键词命中数据。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(bundle.keywordTerms.enumerated()), id: \.offset) { _, term in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(term.term)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(2)
                                    .help(term.term)
                                HStack(spacing: 14) {
                                    Text("命中 \(term.total)")
                                    Text("纳入 \(term.included)")
                                    Text("独有纳入 \(term.uniqueIncluded)")
                                        .foregroundStyle(term.uniqueIncluded == 0 && term.included > 0 ? Theme.amber : Theme.muted)
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                            }
                            .padding(.vertical, 8)
                            Divider().overlay(Theme.line.opacity(0.74))
                        }
                    }
                }
                .frame(maxHeight: 360)
                .background(Theme.panel2.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    // MARK: - 高级卡片：期刊策略

    private func journalRecommendationsContent(_ bundle: StatsBundle) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("以下仅呈现当前期刊清单与人工复筛数据的交集，不会自动修改你的期刊列表。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    suggestionSection(
                        title: "清单外的已纳入期刊",
                        subtitle: "不在当前期刊清单、但已有至少 2 篇人工纳入文章。",
                        rows: bundle.suggestAdd,
                        color: Theme.green,
                        right: { journal in "纳入 \(journal.included) / 已复筛 \(journal.reviewed)" }
                    )

                    Divider().overlay(Theme.line)

                    suggestionSection(
                        title: "清单内的零纳入期刊",
                        subtitle: "在当前期刊清单中、已复筛至少 5 篇但暂无人工纳入文章。",
                        rows: bundle.suggestPrune,
                        color: Theme.amber,
                        right: { journal in "已复筛 \(journal.reviewed) / 收录 \(journal.total)" }
                    )
                }
            }
            .frame(maxHeight: 360)
            .background(Theme.panel2.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    @ViewBuilder private func suggestionSection(
        title: String,
        subtitle: String,
        rows: [JournalStat],
        color: Color,
        right: @escaping (JournalStat) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)

            if rows.isEmpty {
                Text("暂无符合当前规则的期刊。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            } else {
                ForEach(rows) { journal in
                    HStack(spacing: 10) {
                        Text(journal.journal)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .help(journal.journal)
                        Spacer(minLength: 12)
                        Text(right(journal))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: - Initial loading

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                SectionTitle("总览")
                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.panel2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 104)
                    }
                }
            }

            ForEach(StatsCardID.defaultOrder) { card in
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: card.symbol)
                            .foregroundStyle(Theme.muted)
                            .frame(width: 18)
                        Text(card.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.panel2)
                        .frame(height: card == .years || card == .journals ? 120 : 42)
                }
            }
        }
    }
}

/// macOS 没有 iOS 的 EditMode。这里使用原生拖放完成排序，拖到目标卡片上方即可插入。
private struct StatsCardDropDelegate: DropDelegate {
    let target: StatsCardID
    @Binding var order: [StatsCardID]
    @Binding var dragging: StatsCardID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let sourceIndex = order.firstIndex(of: dragging),
              let targetIndex = order.firstIndex(of: target) else { return }

        withAnimation(.easeInOut(duration: 0.16)) {
            order.remove(at: sourceIndex)
            let insertionIndex = order.firstIndex(of: target) ?? min(targetIndex, order.endIndex)
            order.insert(dragging, at: insertionIndex)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private enum YearScale: String, CaseIterable, Identifiable {
    case logarithmic
    case linear

    var id: String { rawValue }
    var label: String { self == .logarithmic ? "对数" : "线性" }
}

private enum JournalSort: String {
    case journal
    case total
    case pending
    case included
    case excluded
    case rate
}

private enum JournalColumns {
    static let nameMinimum: CGFloat = 240
    static let total: CGFloat = 50
    static let pending: CGFloat = 56
    static let included: CGFloat = 48
    static let excluded: CGFloat = 48
    static let rate: CGFloat = 56
    static let horizontalInset: CGFloat = 10
}

private enum SourceCodeHelp {
    static let text = "来源代码来自 Europe PMC。MED 为 PubMed/MEDLINE；PMC 为 PubMed Central；PPR 为预印本；AGR 为 Agricola；CTX 为 CiteXplore。其他代码同样表示 Europe PMC 的上游来源，而不是文献质量等级。"
}

private struct StatsInfoButton: View {
    let title: String
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }
}

// 横向占比条：基础分布与提示词评估共用。
struct ProportionBar: View {
    let segments: [(label: String, count: Int, color: Color)]

    private var total: Int { segments.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.count > 0 {
                            Rectangle()
                                .fill(segment.color)
                                .frame(width: total > 0 ? geometry.size.width * CGFloat(segment.count) / CGFloat(total) : 0)
                        }
                    }
                }
            }
            .frame(height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            FlexLegend(segments: segments, total: total)
        }
    }
}

private struct FlexLegend: View {
    let segments: [(label: String, count: Int, color: Color)]
    let total: Int

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment.color)
                        .frame(width: 9, height: 9)
                    Text("\(segment.label) \(segment.count)\(percentage(segment.count))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
        }
    }

    private func percentage(_ count: Int) -> String {
        guard total > 0 else { return "" }
        return "（\(Int((Double(count) / Double(total) * 100).rounded()))%）"
    }
}

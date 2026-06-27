import SwiftUI
import Charts

// 统计页：总览卡 + 年代分布(堆叠) + 来源构成 + 各问题筛选概况 + 复筛进度 + Top 期刊。

struct StatsView: View {
    @EnvironmentObject var app: AppState
    @State private var bundle: StatsBundle?
    @State private var loading = true
    @State private var dimColumn = "include"   // 年代图上色维度

    var body: some View {
        PageContainer {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    PageHeader(title: "统计", subtitle: "语料构成、筛选与复筛进度一览")
                    Spacer()
                    Button { load() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted)
                }

                if loading {
                    Card { Text("正在统计…").font(.system(size: 13)).foregroundStyle(Theme.muted) }
                } else if let b = bundle, (b.overview["total"] ?? 0) > 0 {
                    overviewCard(b)
                    journalRankCard(b)
                    journalSuggestCard(b)
                    agreementCard(b)
                    yearCard(b)
                    sourceCard(b)
                    questionsCard(b)
                    if !b.topJournals.isEmpty { journalsCard(b) }
                } else {
                    Card {
                        Text("数据库为空——先到「运行」下载并合并文献。")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        loading = true
        app.computeStats { b in
            bundle = b
            if let b, !b.dimensions.contains(where: { $0.column == dimColumn }) {
                dimColumn = b.dimensions.first?.column ?? "include"
            }
            loading = false
        }
    }

    // ── 总览 ────────────────────────────────────────────────────────────────────

    private func overviewCard(_ b: StatsBundle) -> some View {
        Card {
            SectionTitle("总览")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(overviewItems(b), id: \.label) { it in
                    StatCard(value: it.value, label: it.label, color: it.color)
                }
            }
        }
    }

    private func overviewItems(_ b: StatsBundle) -> [(label: String, value: Int, color: Color)] {
        var items: [(String, Int, Color)] = []
        items.append(("总文章数", b.overview["total"] ?? 0, Theme.accent))
        items.append(("已纳入", b.overview["reviewed_yes"] ?? 0, Theme.green))
        items.append(("已排除", b.overview["reviewed_no"] ?? 0, Theme.muted))
        items.append(("待复筛", b.overview["reviewed_pending"] ?? 0, Theme.amber))
        return items.map { (label: $0.0, value: $0.1, color: $0.2) }
    }

    // ── ① 年代分布（堆叠柱状）─────────────────────────────────────────────────────

    private func yearCard(_ b: StatsBundle) -> some View {
        Card {
            HStack {
                SectionTitle("年代分布")
                Spacer()
                if b.dimensions.count > 1 {
                    Picker("", selection: $dimColumn) {
                        ForEach(b.dimensions) { d in Text(d.label).tag(d.column) }
                    }.frame(width: 180).labelsHidden()
                }
            }
            Text(verbatim: "按「\(dimLabel(b))」着色：命中 / 未命中 / 未处理")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)

            let segs = yearSegments(b)
            if segs.isEmpty {
                Text("无带年份的数据。").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                Chart(segs) { s in
                    BarMark(x: .value("年份", String(s.year)), y: .value("数量", s.count))
                        .foregroundStyle(by: .value("类别", s.category))
                }
                .chartForegroundStyleScale(["命中": Theme.green, "未命中": Theme.muted.opacity(0.6), "未处理": Theme.line])
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 240)
            }
        }
    }

    private func dimLabel(_ b: StatsBundle) -> String {
        b.dimensions.first(where: { $0.column == dimColumn })?.label ?? "维度"
    }

    private struct YearSeg: Identifiable {
        let id = UUID(); let year: Int; let category: String; let count: Int
    }

    private func yearSegments(_ b: StatsBundle) -> [YearSeg] {
        guard let raw = b.yearRaw[dimColumn] else { return [] }
        let isInclude = dimColumn == "include"
        var agg: [Int: [String: Int]] = [:]
        for (year, value, count) in raw {
            let cat: String
            switch value {
            case (isInclude ? "yes" : "是"): cat = "命中"
            case (isInclude ? "no" : "否"): cat = "未命中"
            default: cat = "未处理"
            }
            agg[year, default: [:]][cat, default: 0] += count
        }
        var segs: [YearSeg] = []
        for year in agg.keys.sorted() {
            for cat in ["命中", "未命中", "未处理"] {
                if let c = agg[year]?[cat], c > 0 { segs.append(YearSeg(year: year, category: cat, count: c)) }
            }
        }
        return segs
    }

    // ── ② 来源构成 ──────────────────────────────────────────────────────────────

    private func sourceCard(_ b: StatsBundle) -> some View {
        Card {
            SectionTitle("来源构成")
            ProportionBar(segments: b.sources.map { (v, c) in
                (label: sourceLabel(v), count: c, color: sourceColor(v))
            })
        }
    }

    private func sourceLabel(_ v: String?) -> String {
        switch v { case "MED": return "正式发表 (MED)"; case "PPR": return "预印本 (PPR)"
        case .some(let s) where !s.isEmpty: return s; default: return "未知" }
    }
    private func sourceColor(_ v: String?) -> Color {
        switch v { case "MED": return Theme.accent; case "PPR": return Theme.amber; default: return Theme.muted }
    }

    // ── ③ 各问题筛选概况 ────────────────────────────────────────────────────────

    private func questionsCard(_ b: StatsBundle) -> some View {
        Card {
            SectionTitle("各问题筛选概况")
            if b.questions.isEmpty {
                Text("尚无分类问题。").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(b.questions, id: \.question.id) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.question.displayName).font(.system(size: 14, weight: .medium))
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
    }

    // ── ① 期刊入选率榜 ──────────────────────────────────────────────────────────

    private func journalRankCard(_ b: StatsBundle) -> some View {
        Card {
            SectionTitle("期刊入选率")
            Text(verbatim: "已复筛 ≥ 5 篇的期刊，按入选率排序。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            if b.journalRank.isEmpty {
                Text("复筛样本不足。").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(b.journalRank.prefix(15), id: \.journal) { j in journalRateRow(j) }
                }
            }
        }
    }

    private func journalRateRow(_ j: JournalStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(j.journal).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int((j.rate * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(rateColor(j.rate))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.line).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3).fill(rateColor(j.rate))
                        .frame(width: geo.size.width * j.rate, height: 6)
                }
            }
            .frame(height: 6)
            Text(verbatim: "纳入 \(j.included) / 已复筛 \(j.reviewed)（共 \(j.total)）")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private func rateColor(_ r: Double) -> Color {
        r >= 0.5 ? Theme.green : (r >= 0.2 ? Theme.amber : Theme.muted)
    }

    // ── ② 期刊列表反哺 ──────────────────────────────────────────────────────────

    private func journalSuggestCard(_ b: StatsBundle) -> some View {
        Card {
            SectionTitle("期刊列表建议")

            Text("建议加入").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.green)
            Text(verbatim: "不在期刊列表、却已有纳入文章的期刊（多由检索词带回）。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            if b.suggestAdd.isEmpty {
                Text("暂无。").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                ForEach(b.suggestAdd.prefix(10), id: \.journal) { j in
                    suggestRow(j.journal, right: "纳入 \(j.included) / 复筛 \(j.reviewed)")
                }
            }

            Divider().overlay(Theme.line).padding(.vertical, 4)

            Text("建议精简").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.amber)
            Text(verbatim: "在列表中、已复筛 ≥ 5 篇但无一纳入的期刊。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            if b.suggestPrune.isEmpty {
                Text("暂无。").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                ForEach(b.suggestPrune.prefix(10), id: \.journal) { j in
                    suggestRow(j.journal, right: "复筛 \(j.reviewed) / 共 \(j.total)")
                }
            }
        }
    }

    private func suggestRow(_ name: String, right: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            Text(right).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    // ── ④ AI vs 人工一致性 ──────────────────────────────────────────────────────

    private func agreementCard(_ b: StatsBundle) -> some View {
        Card {
            SectionTitle("AI 与人工一致性")
            Text(verbatim: "仅统计已复筛且有 AI 答案的文章。漏判/误纳可用于优化提示词。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            if b.agreements.isEmpty {
                Text("尚无可对照的数据。").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(b.agreements, id: \.question.id) { ag in agreementRow(ag) }
                }
            }
        }
    }

    @ViewBuilder private func agreementRow(_ ag: QAgreement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ag.question.displayName).font(.system(size: 14, weight: .medium))
                Spacer()
                Text(verbatim: "一致率 \(Int((ag.agreeRate * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            ProportionBar(segments: [
                (label: "一致", count: ag.tp + ag.tn, color: Theme.green),
                (label: "AI 漏判", count: ag.fn, color: Theme.amber),
                (label: "AI 误纳", count: ag.fp, color: Theme.red),
            ])
            if !ag.falseNeg.isEmpty {
                Expander("AI 漏判示例（AI 判否、你纳入）· \(ag.fn)") { exampleList(ag.falseNeg) }
            }
            if !ag.falsePos.isEmpty {
                Expander("AI 误纳示例（AI 判是、你排除）· \(ag.fp)") { exampleList(ag.falsePos) }
            }
        }
    }

    private func exampleList(_ items: [(title: String, reason: String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, ex in
                VStack(alignment: .leading, spacing: 2) {
                    Text(ex.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    if !ex.reason.isEmpty {
                        Text(ex.reason).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(3)
                    }
                }
            }
        }
    }

    // ── ⑤ Top 期刊 ──────────────────────────────────────────────────────────────

    private func journalsCard(_ b: StatsBundle) -> some View {
        Card {
            SectionTitle("Top 10 期刊")
            Chart(b.topJournals, id: \.value) { item in
                BarMark(x: .value("数量", item.count), y: .value("期刊", item.value))
                    .foregroundStyle(Theme.accent)
                    .annotation(position: .trailing) {
                        Text("\(item.count)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
            }
            .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 11)) } }
            .frame(height: CGFloat(b.topJournals.count) * 28 + 20)
        }
    }
}

// 横向占比条：按数量比例分段着色 + 图例。
struct ProportionBar: View {
    let segments: [(label: String, count: Int, color: Color)]

    private var total: Int { segments.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                        if s.count > 0 {
                            Rectangle().fill(s.color)
                                .frame(width: total > 0 ? geo.size.width * CGFloat(s.count) / CGFloat(total) : 0)
                        }
                    }
                }
            }
            .frame(height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            FlexLegend(segments: segments, total: total)
        }
    }
}

private struct FlexLegend: View {
    let segments: [(label: String, count: Int, color: Color)]
    let total: Int

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 9, height: 9)
                    Text(verbatim: "\(s.label) \(s.count)\(pct(s.count))")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
        }
    }
    private func pct(_ c: Int) -> String {
        guard total > 0 else { return "" }
        return "（\(Int((Double(c) / Double(total) * 100).rounded()))%）"
    }
}

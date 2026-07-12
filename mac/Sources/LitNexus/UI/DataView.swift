import SwiftUI

struct DataView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accentPalette) private var palette
    @State private var filter = "pending"
    @State private var showClear = false
    @State private var clearConfirm = ""
    @State private var reviewImportPlan: ReviewedCSVImportPlan?
    @State private var reviewImportError: String?
    @State private var isPreparingReviewImport = false

    var body: some View {
        PageContainer {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "数据", guide: PageGuides.data, symbol: Page.data.symbol)

                Card {
                    HStack {
                        SectionTitle("状态")
                        Spacer()
                        Button { app.refreshStats() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted)
                    }
                    if app.stats.isEmpty {
                        Text("数据库尚未创建——先到「运行」执行下载 + 合并。")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    } else {
                        reviewFunnel
                    }
                }

                Card {
                    HStack(spacing: 5) {
                        SectionTitle("导出 CSV")
                        InlineHelpButton(
                            title: "导出的 CSV 怎么复筛？",
                            text: "导出文件始终保留 epmc_id、include 与 tags。复筛时只填写 include（yes 或 no）和可选 tags；其他列仅供阅读，导回时不会覆盖数据库。"
                        )
                        Spacer(minLength: 0)
                    }
                    scopeChips
                    Expander("选择导出列") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: "勾选写入 CSV 的列。问题的答案与理由列在「配置 → 分类问题」中单独控制。")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 6) {
                            ForEach(app.exportableColumns(), id: \.col) { item in
                                let lockedForReview = ["epmc_id", "include", "tags"].contains(item.col)
                                Toggle(item.label, isOn: Binding(
                                    get: { !app.config.export.excludeColumns.contains(item.col) },
                                    set: { app.setColumnExported(item.col, $0) }
                                ))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 13))
                                .disabled(lockedForReview)
                                .help(lockedForReview ? "人工复筛 CSV 必须保留这一列" : "控制该列是否写入导出 CSV")
                            }
                        }
                    }
                    }
                    HStack(spacing: 8) {
                        Button("导出 CSV") { app.export(filter: filter) }
                            .buttonStyle(PrimaryButtonStyle()).disabled(app.stats["total"] == nil)
                        Button("打开导出目录") {
                            if let ws = app.workspace { revealInFinder(ws.exportsDir) }
                        }.buttonStyle(OutlineButtonStyle())
                    }
                }

                Card {
                    HStack(spacing: 5) {
                        SectionTitle("导入复筛结果")
                        InlineHelpButton(
                            title: "复筛 CSV 怎么填写？",
                            text: "只按 epmc_id 匹配，只读取 include 与 tags。include 只能填 yes 或 no；留空表示本次不改动。其他列可用于阅读，修改后不会写回。导入前会先检查重复 ID、非法值、未匹配行和覆盖冲突。"
                        )
                        Spacer(minLength: 0)
                    }
                    Text("选择 CSV 后会先检查，不会立即写入数据库。默认只填补空的人工标注。")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Button {
                        chooseReviewCSV()
                    } label: {
                        if isPreparingReviewImport {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("选择 CSV 并检查…", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isPreparingReviewImport)
                }

                databaseCard
            }
        }
        .onAppear {
            let saved = app.config.export.filter
            filter = ["all", "pending", "included", "excluded"].contains(saved) ? saved : "pending"
            app.refreshStats()
        }
        .sheet(isPresented: $showClear) { clearSheet }
        .sheet(item: $app.importPlan) { plan in ImportMappingSheet(plan: plan) }
        .sheet(item: $reviewImportPlan) { plan in ReviewCSVImportSheet(plan: plan) }
        .alert("无法检查复筛 CSV", isPresented: Binding(
            get: { reviewImportError != nil },
            set: { if !$0 { reviewImportError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(reviewImportError ?? "")
        }
    }

    private func chooseReviewCSV() {
        guard !isPreparingReviewImport, let url = FolderPicker.pickCSV() else { return }
        isPreparingReviewImport = true
        app.prepareReviewCSVImport(url) { result in
            isPreparingReviewImport = false
            switch result {
            case .success(let plan):
                reviewImportPlan = plan
            case .failure(let error):
                reviewImportError = error.localizedDescription
            }
        }
    }

    private var databaseCard: some View {
        Card {
            Expander("数据库") {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: "支持整库备份导出，或从其他库导入合并。导出为标准 .db 格式，可在其他设备或项目中导入接续。")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        Button("导出数据库（备份）") {
                            let name = (app.workspace?.root.lastPathComponent ?? "litnexus") + "_" + EPMCClient.timestamp() + ".db"
                            if let dest = FolderPicker.saveDB(defaultName: name) { app.exportDatabase(to: dest) }
                        }.buttonStyle(PrimaryButtonStyle())
                        Button("导入数据库（跳过已有）") {
                            if let src = FolderPicker.pickDB() { app.beginImport(from: src, strategy: .skipExisting) }
                        }.buttonStyle(OutlineButtonStyle())
                    }
                    Text(verbatim: "导入默认跳过已有文章，不覆盖现有翻译与分类，并在导入前自动备份为 .db.bak。源库若包含分类问题，需先手动对齐问题列。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Button("高级导入：仅填补空缺字段…") {
                        if let src = FolderPicker.pickDB() { app.beginImport(from: src, strategy: .fillEmpty) }
                    }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(palette.accent)
                    .help("保留已有文章，仅以导入值填补当前为空的字段")
                    Divider().overlay(Theme.line).padding(.vertical, 2)
                    Expander("清空数据库") {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("此操作将永久删除全部文章，不可恢复", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: "保留配置与列结构，仅清空文章数据。")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Button("清空数据库") { clearConfirm = ""; showClear = true }
                                .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.red)
                        }
                    }
                }
            }
        }
    }

    private var clearSheet: some View {
        let projectName = app.workspace?.root.lastPathComponent ?? ""
        return VStack(alignment: .leading, spacing: 14) {
            Text("清空项目数据库").font(.system(size: 17, weight: .bold))
            Text(verbatim: "此操作将永久删除「\(projectName)」中的全部文章（含翻译、分类、复筛标注）。配置与问题保留，数据无法恢复。")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "请输入项目名「\(projectName)」以确认：").font(.system(size: 13)).foregroundStyle(Theme.fg)
            TextField("", text: $clearConfirm).textFieldStyle(.plain)
                .padding(8).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("取消") { showClear = false }.buttonStyle(OutlineButtonStyle())
                Button("清空数据库") {
                    app.clearDatabase(); showClear = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.red)
                .disabled(clearConfirm != projectName || projectName.isEmpty)
            }
        }
        .padding(24).frame(width: 460).background(Theme.panel)
    }

    // 导出范围：一排带计数的可点选芯片，与状态区的数据卡片对应。
    private var scopeChips: some View {
        HStack(spacing: 8) {
            ScopeChip(label: "全部", count: app.stats["total"] ?? 0,
                      selected: filter == "all") { selectExportFilter("all") }
            ScopeChip(label: "待复筛", count: app.stats["reviewed_pending"] ?? 0,
                      selected: filter == "pending") { selectExportFilter("pending") }
            ScopeChip(label: "纳入", count: app.stats["reviewed_yes"] ?? 0,
                      selected: filter == "included") { selectExportFilter("included") }
            ScopeChip(label: "排除", count: app.stats["reviewed_no"] ?? 0,
                      selected: filter == "excluded") { selectExportFilter("excluded") }
            Spacer(minLength: 0)
        }
    }

    private func selectExportFilter(_ next: String) {
        filter = next
        app.setExportFilter(next)
    }

    // 复筛漏斗：总数 + 待复筛/纳入/排除（后三者之和 = 总数），一排数字卡片。
    private var reviewFunnel: some View {
        MetricsRow(items: [
            (value: app.stats["total"] ?? 0, label: "总文章数", color: palette.accent),
            (value: app.stats["reviewed_pending"] ?? 0, label: "待复筛", color: Theme.amber),
            (value: app.stats["reviewed_yes"] ?? 0, label: "纳入", color: Theme.green),
            (value: app.stats["reviewed_no"] ?? 0, label: "排除", color: Theme.red),
        ])
    }

}

/// 复筛 CSV 的第二步：先解释将发生什么，再由用户明确确认写入。
/// 报告来自引擎预检；此视图不自行解析 CSV，避免 UI 与实际写入规则漂移。
private struct ReviewCSVImportSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var plan: ReviewedCSVImportPlan
    @State private var allowOverwrite: Bool
    @State private var isRefreshing = false
    @State private var isImporting = false
    @State private var failure: String?

    init(plan: ReviewedCSVImportPlan) {
        _plan = State(initialValue: plan)
        _allowOverwrite = State(initialValue: plan.allowOverwrite)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("检查复筛 CSV")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.fg)
                    Text(plan.csvPath.lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                importStateBadge
            }

            Text("只按 epmc_id 匹配，只读取 include 与 tags。标题、摘要、期刊、翻译与 AI 结果即使在 CSV 中被修改，也不会写回数据库。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            summaryGrid

            VStack(alignment: .leading, spacing: 6) {
                Toggle("允许覆盖已有人工标注", isOn: $allowOverwrite)
                    .toggleStyle(.switch)
                    .disabled(isRefreshing || isImporting)
                Text(allowOverwrite
                     ? "确认后，CSV 中非空的 include / tags 可以改写已有人工标注。"
                     : "默认只填补数据库中为空的 include / tags；已有值会保留并列为冲突。")
                    .font(.system(size: 11))
                    .foregroundStyle(allowOverwrite ? Theme.amber : Theme.muted)
            }
            .padding(11)
            .background(Theme.panel2.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            if !plan.ignoredColumns.isEmpty {
                Text("已忽略 \(plan.ignoredColumns.count) 个阅读列；它们不会参与回写。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }

            if !plan.issues.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("预检明细")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(plan.issues.prefix(16))) { issue in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: issue.severity == .error ? "xmark.circle.fill" : "exclamationmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(issue.severity == .error ? Theme.red : Theme.amber)
                                        .padding(.top, 1)
                                    Text("第 \(issue.line) 行 · \(issue.message)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.vertical, 6)
                                Divider().overlay(Theme.line.opacity(0.72))
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    if plan.issues.count > 16 {
                        Text("另有 \(plan.issues.count - 16) 项未显示。请先修复 CSV 后重新检查。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }

            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(isImporting)
                Button(action: confirmImport) {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("确认导入")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!plan.canApply || !plan.hasChanges || isRefreshing || isImporting)
            }

            if !plan.canApply {
                Text("存在 \(plan.errorCount) 项错误；修复后才能导入。当前没有写入任何数据。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.red)
            } else if !plan.hasChanges {
                Text("没有可写入的人工标注；可直接取消。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(22)
        .frame(width: 620, alignment: .leading)
        .background(Theme.panel)
        .onChange(of: allowOverwrite) { _ in refreshPlan() }
    }

    private var importStateBadge: some View {
        let isError = plan.errorCount > 0
        let label: String
        if isRefreshing { label = "重新检查中" }
        else if isError { label = "需要修复" }
        else if plan.warningCount > 0 { label = "可确认，含提示" }
        else { label = "可以导入" }
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isError ? Theme.red : (plan.warningCount > 0 ? Theme.amber : Theme.green))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background((isError ? Theme.red : (plan.warningCount > 0 ? Theme.amber : Theme.green)).opacity(0.12))
            .clipShape(Capsule())
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ReviewImportMetric(value: plan.totalRows, label: "数据行", color: Theme.fg)
            ReviewImportMetric(value: plan.updates.count, label: "拟写入行", color: Theme.green)
            ReviewImportMetric(value: plan.plannedIncludeUpdates + plan.plannedTagUpdates, label: "拟写入字段", color: Theme.green)
            ReviewImportMetric(value: plan.emptyRows + plan.unchangedRows, label: "空白／未改变", color: Theme.muted)
            ReviewImportMetric(value: plan.unknownRows, label: "未匹配", color: Theme.amber)
            ReviewImportMetric(value: plan.conflictedRows, label: "默认保护冲突", color: Theme.amber)
        }
    }

    private func refreshPlan() {
        guard !isRefreshing, !isImporting else { return }
        isRefreshing = true
        failure = nil
        app.prepareReviewCSVImport(plan.csvPath, allowOverwrite: allowOverwrite) { result in
            isRefreshing = false
            switch result {
            case .success(let refreshed): plan = refreshed
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }

    private func confirmImport() {
        guard plan.canApply, plan.hasChanges, !isImporting else { return }
        isImporting = true
        failure = nil
        app.confirmReviewCSVImport(plan.csvPath, allowOverwrite: allowOverwrite) { result in
            isImporting = false
            switch result {
            case .success:
                dismiss()
            case .failure(let error):
                failure = error.localizedDescription
                refreshPlan()
            }
        }
    }
}

private struct ReviewImportMetric: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel2.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// 导入数据库时，把源库的问题列人工对齐到当前问题（或新建/不导入）。
struct ImportMappingSheet: View {
    @EnvironmentObject var app: AppState
    @State var plan: ImportPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入对齐").font(.system(size: 17, weight: .bold))
            Text(verbatim: "源库共 \(plan.total) 篇。文献本体与人工标注（include/tags）将自动合并。以下分类问题需逐个指定对齐方式，未指定的问题列不会合并。")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($plan.rows) { $row in rowView($row) }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Spacer()
                Button("取消") { app.importPlan = nil }.buttonStyle(OutlineButtonStyle())
                Button("开始导入") { app.confirmImport(plan) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24).frame(width: 580).background(Theme.panel)
    }

    @ViewBuilder private func rowView(_ row: Binding<ImportQRow>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "源库问题：\(row.wrappedValue.label)").font(.system(size: 14, weight: .medium))
            if let t = row.wrappedValue.srcText, !t.isEmpty {
                Text(t).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
            } else {
                Text(verbatim: "（源库未自描述问题文本，标识 \(row.wrappedValue.srcId)）")
                    .font(.system(size: 12)).foregroundStyle(Theme.amber)
            }
            Picker("", selection: row.action) {
                ForEach(app.config.classify.questions) { q in
                    Text(verbatim: "对应到：\(q.displayName)").tag(QMapAction.map(q.id))
                }
                Text("新建为独立的一列").tag(QMapAction.createNew)
                Text("不导入这一列").tag(QMapAction.skip)
            }
            .labelsHidden().frame(maxWidth: 320)
        }
        .padding(12)
        .background(Theme.panel2.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// 带计数的可点选范围芯片：选中=靛蓝填充，未选=描边。
struct ScopeChip: View {
    @Environment(\.accentPalette) private var palette
    let label: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 13, weight: .medium))
                Text("\(count)").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? palette.accentForeground.opacity(0.9) : Theme.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(selected ? palette.accentForeground : Theme.fg)
            .background(selected ? palette.accent : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.clear : Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false)
    }
}

struct StatCard: View {
    let value: Int
    let label: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.system(size: 29, weight: .bold)).foregroundStyle(color)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(fill: Theme.panel2, cornerRadius: Theme.radius)
    }
}

/// 数据与统计页共用的关键指标行：四个子卡固定等宽并填满父卡片。
struct MetricsRow: View {
    let items: [(value: Int, label: String, color: Color)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                StatCard(value: item.value, label: item.label, color: item.color)
            }
        }
    }
}

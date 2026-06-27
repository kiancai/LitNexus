import SwiftUI

struct DataView: View {
    @EnvironmentObject var app: AppState
    @State private var filter = "pending"
    @State private var showClear = false
    @State private var clearConfirm = ""

    var body: some View {
        PageContainer {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "数据", subtitle: "库内统计、导出复筛 CSV、导回人工标注")

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
                    SectionTitle("导出 CSV")
                    scopeChips
                    Expander("选择导出列") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: "勾选写入 CSV 的列。问题的答案与理由列在「配置 → 分类问题」中单独控制。")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 6) {
                                ForEach(app.exportableColumns(), id: \.col) { item in
                                    Toggle(item.label, isOn: Binding(
                                        get: { !app.config.export.excludeColumns.contains(item.col) },
                                        set: { app.setColumnExported(item.col, $0) }
                                    )).toggleStyle(.checkbox).font(.system(size: 13))
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
                    SectionTitle("导入复筛结果")
                    Text("选择已在外部编辑的复筛 CSV，将标注写回数据库。")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Button("选择 CSV 导入…") {
                        if let url = FolderPicker.pickCSV() { app.importCSV(url) }
                    }.buttonStyle(OutlineButtonStyle())
                }

                databaseCard
            }
        }
        .onAppear {
            filter = (app.config.export.filter == "all") ? "all" : "pending"
            app.refreshStats()
        }
        .sheet(isPresented: $showClear) { clearSheet }
        .sheet(item: $app.importPlan) { plan in ImportMappingSheet(plan: plan) }
    }

    private var databaseCard: some View {
        Card {
            SectionTitle("数据库")
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
            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.accent)
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
                        .buttonStyle(.bordered).controlSize(.large).tint(Theme.red)
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
                .buttonStyle(PrimaryButtonStyle())
                .disabled(clearConfirm != projectName || projectName.isEmpty)
            }
        }
        .padding(24).frame(width: 460).background(Theme.panel)
    }

    // 导出范围：一排带计数的可点选芯片，与状态区的数据卡片对应。
    private var scopeChips: some View {
        HStack(spacing: 8) {
            ScopeChip(label: "待复筛", count: app.stats["reviewed_pending"] ?? 0,
                      selected: filter == "pending") { filter = "pending" }
            ScopeChip(label: "纳入", count: app.stats["reviewed_yes"] ?? 0,
                      selected: filter == "included") { filter = "included" }
            ScopeChip(label: "排除", count: app.stats["reviewed_no"] ?? 0,
                      selected: filter == "excluded") { filter = "excluded" }
            ScopeChip(label: "全部", count: app.stats["total"] ?? 0,
                      selected: filter == "all") { filter = "all" }
            Spacer(minLength: 0)
        }
    }

    // 复筛漏斗：总数 + 待复筛/纳入/排除（后三者之和 = 总数），一排数字卡片。
    private var reviewFunnel: some View {
        HStack(spacing: 12) {
            StatCard(value: app.stats["total"] ?? 0, label: "总文章数", color: Theme.accent)
            StatCard(value: app.stats["reviewed_pending"] ?? 0, label: "待复筛", color: Theme.amber)
            StatCard(value: app.stats["reviewed_yes"] ?? 0, label: "纳入", color: Theme.green)
            StatCard(value: app.stats["reviewed_no"] ?? 0, label: "排除", color: Theme.red)
        }
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
    let label: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 13, weight: .medium))
                Text("\(count)").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Theme.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Theme.fg)
            .background(selected ? Theme.accent : Color.clear)
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
        .background(Theme.panel2)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

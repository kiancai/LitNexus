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
                        statGroup("总览", [("总文章数", app.stats["total"] ?? 0, Theme.accent)])
                        statGroup("处理进度", progressItems)
                        statGroup("复筛", [("待复筛", app.stats["reviewed_pending"] ?? 0, Theme.amber)])
                        Text(verbatim: "纳入/排除数量、各问题占比、年代与来源分布等分析，在「统计」页查看。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }

                Card {
                    SectionTitle("导出 CSV")
                    HStack(spacing: 12) {
                        Picker("导出范围", selection: $filter) {
                            Text("待复筛").tag("pending")
                            Text("已纳入").tag("included")
                            Text("已排除").tag("excluded")
                            Text("全部").tag("all")
                        }.frame(width: 240)
                    }
                    Expander("选择导出列") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: "勾选要写入 CSV 的列。问题的答案/理由列由「配置 → 分类问题」里各自的「导出」开关控制。")
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
                    Text("选择在 Excel 编辑过的 CSV，标注会写回数据库。")
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
            Text(verbatim: "整库可备份导出、从别处导入合并、或清空。导出为新格式 .db，可在另一台机器或新项目里导入接续。")
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
            Text(verbatim: "导入默认跳过已有文章、不覆盖你的翻译与分类，且导入前自动备份为 .db.bak。若源库含分类问题，会先让你手动对齐。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Button("高级导入：仅填补空缺字段…") {
                if let src = FolderPicker.pickDB() { app.beginImport(from: src, strategy: .fillEmpty) }
            }
            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.accent)
            .help("已有文章保留，只把当前为空的字段用导入值补上")
            Divider().overlay(Theme.line).padding(.vertical, 2)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("清空当前项目").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.red)
                    Text(verbatim: "删除本项目数据库中的全部文章，保留配置与列结构。不可恢复。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("清空…") { clearConfirm = ""; showClear = true }
                    .buttonStyle(OutlineButtonStyle())
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

    // 处理进度（待办类）：待译标题/摘要、各启用问题的待分类数。
    private var progressItems: [(String, Int, Color)] {
        var items: [(String, Int, Color)] = []
        items.append(("待译标题", app.stats["pending_translation"] ?? 0, Theme.cyan))
        if app.stats["pending_abstract_translation"] != nil {
            items.append(("待译摘要", app.stats["pending_abstract_translation"] ?? 0, Theme.cyan))
        }
        for q in app.config.classify.questions where q.classify {
            if let v = app.stats["pending_\(q.id)"] { items.append(("待分类 \(q.displayName)", v, Theme.cyan)) }
        }
        return items
    }

    @ViewBuilder private func statGroup(_ title: String, _ items: [(String, Int, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            if items.allSatisfy({ $0.1 == 0 }) && title == "处理进度" {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    Text("全部处理完成").font(.system(size: 14)).foregroundStyle(Theme.green)
                }.padding(.vertical, 4)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(items, id: \.0) { item in
                        StatCard(value: item.1, label: item.0, color: item.2)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

// 导入数据库时，把源库的问题列人工对齐到当前问题（或新建/不导入）。
struct ImportMappingSheet: View {
    @EnvironmentObject var app: AppState
    @State var plan: ImportPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入对齐").font(.system(size: 17, weight: .bold))
            Text(verbatim: "源库共 \(plan.total) 篇。文献本体与人工标注（include/tags）会自动合并；下面的分类问题请逐个选择如何对齐——这一步不会默认对齐，避免把含义不同的问题列合到一起。")
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

import SwiftUI

struct DataView: View {
    @EnvironmentObject var app: AppState
    @State private var filter = "pending"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "数据", subtitle: "库内统计、导出复筛 CSV、导回人工标注")

                Card {
                    HStack {
                        SectionTitle("统计")
                        Spacer()
                        Button { app.refreshStats() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted)
                    }
                    if app.stats.isEmpty {
                        Text("数据库尚未创建——先到「运行」执行下载 + 合并。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(statItems, id: \.label) { item in
                                StatCard(value: item.value, label: item.label, color: item.color)
                            }
                        }
                    }
                }

                Card {
                    SectionTitle("导出 CSV")
                    HStack(spacing: 12) {
                        Picker("导出范围", selection: $filter) {
                            Text("未复筛 (pending)").tag("pending")
                            Text("全部 (all)").tag("all")
                        }.frame(width: 240)
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
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Button("选择 CSV 导入…") {
                        if let url = FolderPicker.pickCSV() { app.importCSV(url) }
                    }.buttonStyle(OutlineButtonStyle())
                }
            }
            .padding(28)
        }
        .onAppear {
            filter = (app.config.export.filter == "all") ? "all" : "pending"
            app.refreshStats()
        }
    }

    private var statItems: [(label: String, value: Int, color: Color)] {
        var items: [(String, Int, Color)] = []
        if let v = app.stats["total"] { items.append(("总文章数", v, Theme.accent)) }
        if let v = app.stats["pending_translation"] { items.append(("待翻译", v, Theme.cyan)) }
        for q in app.config.classify.questions {
            if let v = app.stats["pending_\(q.id)"] { items.append(("待分类 \(q.id)", v, Theme.cyan)) }
        }
        if let v = app.stats["reviewed_yes"] { items.append(("已收 yes", v, Theme.green)) }
        if let v = app.stats["reviewed_no"] { items.append(("已弃 no", v, Theme.muted)) }
        return items.map { (label: $0.0, value: $0.1, color: $0.2) }
    }
}

struct StatCard: View {
    let value: Int
    let label: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.system(size: 28, weight: .bold)).foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel2)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

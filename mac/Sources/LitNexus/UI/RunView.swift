import SwiftUI

struct RunView: View {
    @EnvironmentObject var app: AppState
    @State private var mode = "all"
    @State private var days = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "运行", subtitle: "下载 → 合并 → 翻译 → 分类，一条流水线跑到底")

                Card {
                    SectionTitle("检索范围")
                    HStack(spacing: 16) {
                        Picker("下载模式", selection: $mode) {
                            Text("全部").tag("all")
                            Text("仅期刊").tag("journals")
                            Text("仅关键词").tag("keywords")
                        }
                        .frame(width: 220)
                        HStack(spacing: 6) {
                            Text("最近 N 天").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            TextField("", value: $days, format: .number)
                                .textFieldStyle(.plain).frame(width: 60)
                                .padding(6).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    HStack(spacing: 8) {
                        Button("▶ 一键全跑") { app.runAll(mode: mode, days: days) }
                            .buttonStyle(PrimaryButtonStyle()).disabled(app.isRunning)
                        Button("① 下载") { app.runDownload(mode: mode, days: days) }
                            .buttonStyle(OutlineButtonStyle()).disabled(app.isRunning)
                        Button("② 合并") { app.runMerge() }
                            .buttonStyle(OutlineButtonStyle()).disabled(app.isRunning)
                        Button("③ 翻译") { app.runTranslate() }
                            .buttonStyle(OutlineButtonStyle()).disabled(app.isRunning)
                        Button("④ 分类") { app.runClassify() }
                            .buttonStyle(OutlineButtonStyle()).disabled(app.isRunning)
                        if app.isRunning { ProgressView().controlSize(.small).padding(.leading, 4) }
                    }

                    logPane
                    Text("跑完后到「数据」页查看统计并导出。")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            .padding(28)
        }
        .onAppear { days = app.config.download.days }
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(app.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .frame(height: 260)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onChange(of: app.logLines.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

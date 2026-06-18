import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    @State private var journals = ""
    @State private var keywords = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var questions: [Question] = []
    @State private var days = 30
    @State private var pageSize = 1000
    @State private var requestDelay = 0.5
    @State private var batchSize = 30
    @State private var concurrency = 20
    @State private var maxWorkers = 100
    @State private var exportFilter = "pending"
    @State private var excludeColumns = ""
    @State private var customColumns = ""
    @State private var testing = false
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "配置", subtitle: "检索范围、AI 接口、初筛问题，以及不常动的高级项")

                Card {
                    SectionTitle("检索列表")
                    label("期刊")
                    editor($journals, height: 120)
                    label("关键词检索式")
                    editor($keywords, height: 90)
                }

                Card {
                    SectionTitle("AI 接口")
                    label("Base URL"); input($baseURL)
                    label("模型名"); input($model)
                    label("API Key")
                    SecureField("", text: $apiKey).textFieldStyle(.plain)
                        .padding(8).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
                    Button(testing ? "测试中…" : "测试连接") {
                        testing = true
                        app.testAIConnection(AIConfig(apiKey: apiKey, baseURL: baseURL, model: model)) { _, m in
                            testing = false; app.toast = m
                        }
                    }.buttonStyle(OutlineButtonStyle()).disabled(testing)
                }

                Card {
                    SectionTitle("分类问题（AI 初筛 Prompt）")
                    ForEach(questions.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("列名 id", text: $questions[i].id).textFieldStyle(.plain)
                                    .frame(width: 120).padding(6)
                                    .background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 6))
                                Spacer()
                                Button { questions.remove(at: i) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(Theme.red)
                            }
                            editor($questions[i].text, height: 80)
                        }
                        .padding(10)
                        .background(Theme.panel2.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Button("+ 新增问题") { questions.append(Question(id: "q\(questions.count + 1)", text: "")) }
                        .buttonStyle(OutlineButtonStyle())
                }

                Card {
                    DisclosureGroup("高级参数") {
                        VStack(alignment: .leading, spacing: 10) {
                            numberRow("下载最近 N 天", $days)
                            numberRow("page_size", $pageSize)
                            doubleRow("请求间隔(秒)", $requestDelay)
                            numberRow("翻译批量", $batchSize)
                            numberRow("翻译并发", $concurrency)
                            numberRow("分类并发", $maxWorkers)
                            label("导出筛选（默认范围）"); input($exportFilter)
                            label("导出排除列（逗号分隔）"); input($excludeColumns)
                            label("人工标注列（逗号分隔）"); input($customColumns)
                        }.padding(.top, 8)
                    }.tint(Theme.fg)
                }

                Card {
                    DisclosureGroup("项目位置 / 文件") {
                        if let ws = app.workspace {
                            VStack(alignment: .leading, spacing: 6) {
                                pathRow("配置文件", ws.configPath)
                                pathRow("数据库", ws.dbPath)
                                pathRow("下载目录", ws.downloadsDir)
                                pathRow("导出目录", ws.exportsDir)
                                HStack(spacing: 8) {
                                    Button("切换项目") { app.switchProject() }.buttonStyle(OutlineButtonStyle())
                                    Button("打开项目目录") { revealInFinder(ws.root) }.buttonStyle(OutlineButtonStyle())
                                }.padding(.top, 4)
                            }.padding(.top, 8)
                        }
                    }.tint(Theme.fg)
                }

                Button("保存配置") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
            }
            .padding(28)
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let c = app.config
        journals = app.readJournals(); keywords = app.readKeywords()
        baseURL = c.ai.baseURL; model = c.ai.model; apiKey = c.ai.apiKey
        questions = c.classify.questions
        days = c.download.days; pageSize = c.download.pageSize; requestDelay = c.download.requestDelay
        batchSize = c.translate.batchSize; concurrency = c.translate.concurrency; maxWorkers = c.classify.maxWorkers
        exportFilter = c.export.filter
        excludeColumns = c.export.excludeColumns.joined(separator: ", ")
        customColumns = c.schema.customColumns.joined(separator: ", ")
    }

    private func save() {
        var c = app.config
        c.ai = AIConfig(apiKey: apiKey.trimmingCharacters(in: .whitespaces),
                        baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                        model: model.trimmingCharacters(in: .whitespaces))
        c.classify.questions = questions
            .map { Question(id: $0.id.trimmingCharacters(in: .whitespaces), text: $0.text.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.id.isEmpty && Identifier.isValid($0.id) }
        c.download.days = days; c.download.pageSize = pageSize; c.download.requestDelay = requestDelay
        c.translate.batchSize = batchSize; c.translate.concurrency = concurrency; c.classify.maxWorkers = maxWorkers
        c.export.filter = exportFilter.trimmingCharacters(in: .whitespaces).isEmpty ? "pending" : exportFilter
        c.export.excludeColumns = splitList(excludeColumns)
        c.schema.customColumns = splitList(customColumns).filter { Identifier.isValid($0) }
        app.saveConfig(c, journals: journals, keywords: keywords)
    }

    private func splitList(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // ── 小组件 ────────────────────────────────────────────────────────────────
    @ViewBuilder private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
    }
    @ViewBuilder private func input(_ b: Binding<String>) -> some View {
        TextField("", text: b).textFieldStyle(.plain)
            .padding(8).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func editor(_ b: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: b)
            .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
            .padding(6).frame(height: height)
            .background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func numberRow(_ t: String, _ b: Binding<Int>) -> some View {
        HStack {
            Text(t).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 130, alignment: .leading)
            TextField("", value: b, format: .number).textFieldStyle(.plain).frame(width: 90)
                .padding(6).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
    @ViewBuilder private func doubleRow(_ t: String, _ b: Binding<Double>) -> some View {
        HStack {
            Text(t).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 130, alignment: .leading)
            TextField("", value: b, format: .number).textFieldStyle(.plain).frame(width: 90)
                .padding(6).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
    @ViewBuilder private func pathRow(_ t: String, _ url: URL) -> some View {
        HStack {
            Text(t).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 80, alignment: .leading)
            Text(url.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.fg)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }
}

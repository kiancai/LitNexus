import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    @State private var journals = ""
    @State private var keywords = ""
    @State private var days = 30
    @State private var pageSize = 1000
    @State private var requestDelay = 0.5
    @State private var batchSize = 30
    @State private var concurrency = 20
    @State private var maxWorkers = 20
    @State private var classifyBatchSize = 15
    @State private var classifyAttempts = 3
    @State private var exportFilter = "pending"
    @State private var excludeColumns = ""
    @State private var customColumns = ""
    @State private var loaded = false

    var body: some View {
        PageContainer {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "配置", subtitle: "更改自动保存，无需手动操作")

                Card {
                    SectionTitle("外观")
                    Picker("", selection: Binding(
                        get: { app.appearance },
                        set: { app.setAppearance($0) })) {
                        ForEach(AppAppearance.allCases) { a in
                            Text(a.label).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }

                Card {
                    SectionTitle("检索列表")
                    label("期刊")
                    editor($journals, height: 120)
                    label("关键词检索式")
                    editor($keywords, height: 90)
                }

                AIProfilesCard()

                QuestionsCard()

                Card {
                    Expander("高级参数") {
                        VStack(alignment: .leading, spacing: 10) {
                            numberRow("下载最近天数", $days)
                            numberRow("每页数量", $pageSize)
                            doubleRow("请求间隔（秒）", $requestDelay)
                            numberRow("翻译批量大小", $batchSize)
                            numberRow("翻译并发数", $concurrency)
                            numberRow("分类批量大小", $classifyBatchSize)
                            numberRow("分类并发数（批）", $maxWorkers)
                            numberRow("分类失败重试上限", $classifyAttempts)
                            label("默认导出范围"); input($exportFilter)
                            label("导出排除列（逗号分隔）"); input($excludeColumns)
                            label("人工标注列（逗号分隔）"); input($customColumns)
                        }
                    }
                }

                Card {
                    Expander("项目位置") {
                        if let ws = app.workspace {
                            VStack(alignment: .leading, spacing: 6) {
                                pathRow("配置文件", ws.configPath)
                                pathRow("数据库", ws.dbPath)
                                pathRow("下载目录", ws.downloadsDir)
                                pathRow("导出目录", ws.exportsDir)
                                HStack(spacing: 8) {
                                    Button("切换项目") { persist(); app.switchProject() }.buttonStyle(OutlineButtonStyle())
                                    Button("打开项目目录") { revealInFinder(ws.root) }.buttonStyle(OutlineButtonStyle())
                                }.padding(.top, 4)
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: persist)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let c = app.config
        journals = app.readJournals(); keywords = app.readKeywords()
        days = c.download.days; pageSize = c.download.pageSize; requestDelay = c.download.requestDelay
        batchSize = c.translate.batchSize; concurrency = c.translate.concurrency
        maxWorkers = c.classify.maxWorkers; classifyBatchSize = c.classify.batchSize; classifyAttempts = c.classify.maxAttempts
        exportFilter = c.export.filter
        excludeColumns = c.export.excludeColumns.joined(separator: ", ")
        customColumns = c.schema.customColumns.joined(separator: ", ")
    }

    // 自动保存非 AI 设置（AI 方案由各自的增删选/编辑即时持久化，此处从 app.config 继承不覆盖）。
    private func persist() {
        guard loaded else { return }
        var c = app.config   // 分类问题由 QuestionsCard 即时持久化，这里不覆盖
        c.download.days = days; c.download.pageSize = pageSize; c.download.requestDelay = requestDelay
        c.translate.batchSize = batchSize; c.translate.concurrency = concurrency
        c.classify.maxWorkers = maxWorkers; c.classify.batchSize = classifyBatchSize; c.classify.maxAttempts = classifyAttempts
        c.export.filter = exportFilter.trimmingCharacters(in: .whitespaces).isEmpty ? "pending" : exportFilter
        c.export.excludeColumns = splitList(excludeColumns)
        c.schema.customColumns = splitList(customColumns).filter { Identifier.isValid($0) }
        app.saveConfig(c, journals: journals, keywords: keywords)
    }

    private func splitList(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @ViewBuilder private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
    }
    @ViewBuilder private func input(_ b: Binding<String>) -> some View {
        TextField("", text: b).textFieldStyle(.plain).lineLimit(1)
            .padding(8).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func editor(_ b: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: b)
            .font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
            .padding(6).frame(height: height)
            .background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func numberRow(_ t: String, _ b: Binding<Int>) -> some View {
        HStack {
            Text(t).font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 130, alignment: .leading)
            TextField("", value: b, format: .number).textFieldStyle(.plain).lineLimit(1).frame(width: 90)
                .padding(6).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
    @ViewBuilder private func doubleRow(_ t: String, _ b: Binding<Double>) -> some View {
        HStack {
            Text(t).font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 130, alignment: .leading)
            TextField("", value: b, format: .number).textFieldStyle(.plain).lineLimit(1).frame(width: 90)
                .padding(6).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
    @ViewBuilder private func pathRow(_ t: String, _ url: URL) -> some View {
        HStack {
            Text(t).font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 80, alignment: .leading)
            Text(url.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.fg)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }
}

// ── 分类问题卡片：每个问题独立配置（昵称 / 完整问题 / AI处理 / 导出 / 永久删除）──

struct QuestionsCard: View {
    @EnvironmentObject var app: AppState
    @State private var pendingDelete: Question?

    var body: some View {
        Card {
            SectionTitle("分类问题")
            Text(verbatim: "每个问题独立配置。「AI 处理」决定是否让 AI 跑这个问题；「导出」决定是否写入导出的 CSV；昵称用作导出表头。")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)

            ForEach(app.config.classify.questions) { q in
                if let binding = app.questionBinding(q.id) { editor(binding) }
            }

            Button("添加问题") { app.addQuestion() }.buttonStyle(OutlineButtonStyle())
        }
        .alert("彻底删除这个问题？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除问题及全部答案", role: .destructive) {
                if let q = pendingDelete { app.deleteQuestionPermanently(q.id) }
                pendingDelete = nil
            }
        } message: {
            Text(verbatim: "将连同该问题已有的全部答案与理由一并永久删除，无法恢复。若只是暂时不想用，请改为关闭「AI 处理」。")
        }
    }

    @ViewBuilder private func editor(_ q: Binding<Question>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("昵称（导出表头）", text: q.nickname).textFieldStyle(.plain).lineLimit(1)
                    .padding(7).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: 220)
                Spacer()
                Text(verbatim: "标识 \(q.wrappedValue.id)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Button { pendingDelete = q.wrappedValue } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.red).help("永久删除该问题及其数据")
            }
            TextEditor(text: q.text)
                .font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(6).frame(height: 80)
                .background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 18) {
                Toggle("AI 处理", isOn: q.classify).toggleStyle(.checkbox)
                Toggle("导出到 CSV", isOn: q.export).toggleStyle(.checkbox)
            }.font(.system(size: 13)).foregroundStyle(Theme.fg)
        }
        .padding(12)
        .background(Theme.panel2.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// ── AI 方案卡片：可保存多个方案，选择其一用于翻译与分类 ───────────────────────

struct AIProfilesCard: View {
    @EnvironmentObject var app: AppState
    @State private var testing = false

    var body: some View {
        Card {
            SectionTitle("AI 接口")
            Text("可保存多个配置方案，选择其一用于翻译与分类。")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)

            ForEach(app.config.aiProfiles) { profile in
                let active = profile.id == app.config.activeAIID
                HStack(spacing: 10) {
                    Image(systemName: active ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(active ? Theme.accent : Theme.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name.isEmpty ? "未命名方案" : profile.name)
                            .font(.system(size: 14, weight: .medium))
                        Text(profile.isComplete ? "\(profile.model) · \(profile.baseURL)" : "尚未配置完整")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    Button { app.deleteAIProfile(profile.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Theme.red)
                }
                .padding(10)
                .background(active ? Theme.panel2 : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Theme.accent.opacity(0.4) : Theme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { app.selectAIProfile(profile.id) }
            }

            Button("添加方案") { app.addAIProfile() }.buttonStyle(OutlineButtonStyle())

            if let binding = app.activeProfileBinding() {
                Divider().overlay(Theme.line).padding(.vertical, 4)
                editor(binding)
            }
        }
    }

    @ViewBuilder private func editor(_ p: Binding<AIProfile>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            field("方案名称", p.name)
            field("接口地址（Base URL）", p.baseURL)
            Text(verbatim: "接口地址通常以 /v1 结尾；也可填写完整的 /chat/completions 路径。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            field("模型名称", p.model)
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                SecureField("", text: p.apiKey).textFieldStyle(.plain)
                    .padding(8).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            field("额外请求参数（JSON，可选）", p.extraParams)
            Text(verbatim: "用于服务商各自不同的开关。关闭推理示例：MiMo 用 {\"thinking\": {\"type\": \"disabled\"}}；通义/Qwen 用 {\"enable_thinking\": false}；部分 OpenAI 兼容用 {\"reasoning_effort\": \"minimal\"}。写错的键会被服务器忽略，不报错。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)

            Button(testing ? "测试中…" : "测试连接") {
                testing = true
                app.testAIConnection(p.wrappedValue.asConfig) { _, m in testing = false; app.toast = m }
            }
            .buttonStyle(OutlineButtonStyle()).disabled(testing)
        }
    }

    @ViewBuilder private func field(_ title: String, _ b: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
            TextField("", text: b).textFieldStyle(.plain).lineLimit(1)
                .padding(8).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

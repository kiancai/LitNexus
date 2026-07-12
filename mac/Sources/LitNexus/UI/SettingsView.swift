import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case search
    case ai
    case classify
    case project

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: return "外观"
        case .search: return "检索"
        case .ai: return "AI 与翻译"
        case .classify: return "分类"
        case .project: return "项目"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .search: return "magnifyingglass"
        case .ai: return "sparkles"
        case .classify: return "checklist"
        case .project: return "folder"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accentPalette) private var palette

    @State private var section: SettingsSection = .appearance
    @State private var journals = ""
    @State private var keywords = ""
    @State private var days = 30
    @State private var pageSize = 1000
    @State private var requestDelay = 0.5
    @State private var batchSize = 30
    @State private var concurrency = 20
    @State private var translateAbstract = true
    @State private var abstractBatchSize = 10
    @State private var maxWorkers = 20
    @State private var classifyBatchSize = 15
    @State private var classifyAttempts = 3
    @State private var customColumns = ""
    @State private var loaded = false
    @State private var scheduledSave: DispatchWorkItem?

    var body: some View {
        PageContainer {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "配置", guide: PageGuides.settings, symbol: Page.settings.symbol)
                SettingsSectionRail(selection: sectionBinding)
                sectionContent
            }
        }
        .onAppear(perform: load)
        .onChange(of: persistenceSignature) { _ in schedulePersist() }
        .onDisappear {
            scheduledSave?.cancel()
            persist()
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .appearance: appearanceContent
        case .search: searchContent
        case .ai: aiContent
        case .classify: classifyContent
        case .project: projectContent
        }
    }

    private var sectionBinding: Binding<SettingsSection> {
        Binding(
            get: { section },
            set: { next in
                guard next != section else { return }
                persist()
                withAnimation(.easeInOut(duration: 0.16)) { section = next }
            }
        )
    }

    private var appearanceContent: some View {
        Card {
            SectionTitle("外观")
            Text("显示模式只保存在当前设备；项目强调色会随项目一起保存。")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)

            Picker("显示模式", selection: Binding(
                get: { app.appearance },
                set: { app.setAppearance($0) })) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340, alignment: .leading)

            Divider().overlay(Theme.line).padding(.vertical, 2)

            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(palette.accent)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.accentForeground)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("项目强调色")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.fg)
                    Text(app.config.theme.accentHue == nil ? "使用 LitNexus 默认青绿" : "已为此项目保存自定义色调")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }

                Spacer(minLength: 8)

                ColorPicker("选择项目强调色", selection: app.projectAccentColorBinding(), supportsOpacity: false)
                    .labelsHidden()
                    .help("选择项目强调色")

                Button("恢复默认") { app.setProjectAccentHue(nil) }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(app.config.theme.accentHue == nil)
            }

            Text("色盘只保存色相；浅色和深色所需的明度与对比度会自动推导，并写入项目的 litnexus.toml。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                HStack(spacing: 5) {
                    SectionTitle("检索列表")
                    InlineHelpButton(
                        title: "修改检索列表会发生什么？",
                        text: "这里控制以后下载的范围。新增、删除或改写一行不会删除已入库文章、人工复筛或既有命中记录；若要保留某条旧检索式的审计上下文，建议先把它改为以 # 开头的注释，而不是直接覆盖文本。"
                    )
                    Spacer(minLength: 0)
                }
                Text("每行一条期刊或检索式；以 # 开头的行会作为注释保留。修改仅影响以后下载，不会回写历史数据。")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                label("期刊")
                editor($journals, height: 180)
                label("关键词检索式")
                editor($keywords, height: 130)
            }

            Card {
                SectionTitle("下载参数")
                numberRow("下载最近天数", $days)
                numberRow("每页数量", $pageSize)
                doubleRow("请求间隔（秒）", $requestDelay)
            }
        }
    }

    private var aiContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            AIProfilesCard()

            Card {
                SectionTitle("翻译")
                Text("标题始终翻译；摘要翻译可以按项目需要关闭。")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                Toggle("同时翻译摘要", isOn: $translateAbstract)
                    .toggleStyle(.switch)
                numberRow("标题批量大小", $batchSize)
                numberRow("翻译并发数", $concurrency)
                if translateAbstract {
                    numberRow("摘要批量大小", $abstractBatchSize)
                }
            }
        }
    }

    private var classifyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            QuestionsCard()

            Card {
                SectionTitle("分类执行")
                Text("这些参数影响每次 AI 分类请求的文章数、并发批数及失败后的重试次数。")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                numberRow("分类批量大小", $classifyBatchSize)
                numberRow("分类并发数（批）", $maxWorkers)
                numberRow("失败重试上限", $classifyAttempts)
            }
        }
    }

    @ViewBuilder private var projectContent: some View {
        Card {
            SectionTitle("当前项目")
            Text("项目文件与数据均存放在下列工作区中。")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            if let ws = app.workspace {
                VStack(alignment: .leading, spacing: 8) {
                    pathRow("配置文件", ws.configPath)
                    pathRow("数据库", ws.dbPath)
                    pathRow("下载目录", ws.downloadsDir)
                    pathRow("导出目录", ws.exportsDir)
                }
                Divider().overlay(Theme.line).padding(.vertical, 2)
                HStack(spacing: 8) {
                    Button("打开项目目录") { revealInFinder(ws.root) }.buttonStyle(OutlineButtonStyle())
                    Button("切换项目") { persist(); app.switchProject() }.buttonStyle(OutlineButtonStyle())
                }
            }

            Divider().overlay(Theme.line).padding(.vertical, 2)

            Expander("数据结构（高级）") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Text("额外人工标注列")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.muted)
                        InlineHelpButton(
                            title: "额外人工列是什么？",
                            text: "它们是项目数据库中的可选人工字段。include 与 tags 是固定复筛列，不能删除；复筛 CSV 导入也始终只写入 include 与 tags，不会回写这些额外列。"
                        )
                        Spacer(minLength: 0)
                    }
                    input($customColumns)
                    Text("用逗号分隔；只能使用英文字母、数字与下划线，且不能与文章或 AI 问题列重名。导出时是否包含它们，在“数据 → 选择导出列”中设置。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let c = app.config
        journals = app.readJournals(); keywords = app.readKeywords()
        days = c.download.days; pageSize = c.download.pageSize; requestDelay = c.download.requestDelay
        batchSize = c.translate.batchSize; concurrency = c.translate.concurrency
        translateAbstract = c.translate.translateAbstract; abstractBatchSize = c.translate.abstractBatchSize
        maxWorkers = c.classify.maxWorkers; classifyBatchSize = c.classify.batchSize; classifyAttempts = c.classify.maxAttempts
        customColumns = c.schema.customColumns.joined(separator: ", ")
    }

    // 自动保存非 AI 设置（AI 方案由各自的增删选/编辑即时持久化，此处从 app.config 继承不覆盖）。
    private func persist() {
        guard loaded else { return }
        var c = app.config   // 分类问题由 QuestionsCard 即时持久化，这里不覆盖
        c.download.days = days; c.download.pageSize = pageSize; c.download.requestDelay = requestDelay
        c.translate.batchSize = batchSize; c.translate.concurrency = concurrency
        c.translate.translateAbstract = translateAbstract; c.translate.abstractBatchSize = abstractBatchSize
        c.classify.maxWorkers = maxWorkers; c.classify.batchSize = classifyBatchSize; c.classify.maxAttempts = classifyAttempts
        c.schema.customColumns = SchemaConfig.normalizedAnnotationColumns(splitList(customColumns))
        app.saveConfig(c, journals: journals, keywords: keywords)
    }

    private func schedulePersist() {
        guard loaded else { return }
        scheduledSave?.cancel()
        let work = DispatchWorkItem { persist() }
        scheduledSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private var persistenceSignature: String {
        [
            journals, keywords,
            String(days), String(pageSize), String(requestDelay),
            String(batchSize), String(concurrency),
            String(translateAbstract), String(abstractBatchSize),
            String(maxWorkers), String(classifyBatchSize), String(classifyAttempts),
            customColumns,
        ].joined(separator: "\u{1F}")
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

private struct SettingsSectionRail: View {
    @Binding var selection: SettingsSection
    @Environment(\.accentPalette) private var palette

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 660 {
                sectionButtons(expandsToFillRail: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    sectionButtons(expandsToFillRail: false)
                }
            }
        }
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.panel2.opacity(0.68)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Theme.line.opacity(0.82), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func sectionButtons(expandsToFillRail: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(SettingsSection.allCases) { item in
                let selected = item == selection
                Button {
                    selection = item
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.fg : Theme.muted)
                        .frame(maxWidth: expandsToFillRail ? .infinity : nil, minHeight: 42)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? palette.accentSoft : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(selected ? palette.accentLine.opacity(0.72) : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: expandsToFillRail ? .infinity : nil)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(maxWidth: expandsToFillRail ? .infinity : nil)
    }
}

// ── 分类问题卡片：每个问题独立配置（昵称 / 完整问题 / AI处理 / 导出 / 归档）──

struct QuestionsCard: View {
    @EnvironmentObject var app: AppState
    @State private var pendingArchive: Question?
    @State private var purgeCandidate: Question?
    @State private var showNewQuestion = false

    private var activeQuestions: [Question] {
        app.config.classify.questions.filter(\.isCurrent)
    }

    private var archivedQuestions: [Question] {
        app.config.classify.questions.filter { !$0.isCurrent }
    }

    var body: some View {
        Card {
            HStack(spacing: 5) {
                SectionTitle("分类问题")
                InlineHelpButton(
                    title: "分类问题如何管理？",
                    text: "新增问题默认只用于之后新合并的文章；若要补答历史库，必须明确选择。归档会把问题移出未来 AI 分类、默认统计和导出，但保留原问题、答案与理由；只有输入问题标识确认后才会永久删除。"
                )
                Spacer(minLength: 0)
            }
            Text(verbatim: "每个当前问题独立配置。「AI 处理」决定是否让 AI 跑这个问题；「导出」决定是否写入导出的 CSV；昵称用作导出表头。")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)

            if activeQuestions.isEmpty {
                VStack(spacing: 6) {
                    Label("没有当前分类问题", systemImage: "checklist")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.fg)
                    Text("添加问题，或从下方已归档的问题中恢复一个。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(activeQuestions) { q in
                    QuestionEditor(id: q.id) { question in
                        pendingArchive = question
                    }
                }
            }

            Button("添加问题") { showNewQuestion = true }
                .buttonStyle(OutlineButtonStyle())

            Divider().overlay(Theme.line).padding(.vertical, 2)

            Expander("已归档的问题（\(archivedQuestions.count)）") {
                if archivedQuestions.isEmpty {
                    Text("归档的问题会保留在这里；恢复后会回到当前问题列表。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(archivedQuestions) { question in
                            ArchivedQuestionRow(question: question) {
                                purgeCandidate = question
                            }
                        }
                    }
                }
            }
        }
        .alert("归档这个问题？", isPresented: Binding(
            get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } })) {
            Button("取消", role: .cancel) { pendingArchive = nil }
            Button("归档") {
                guard let question = pendingArchive else { return }
                switch app.archiveQuestion(question.id) {
                case .success(let archived):
                    app.toast = "已归档「\(archived.displayName)」，可在“已归档的问题”中恢复。"
                case .failure(let error):
                    app.toast = error.localizedDescription
                }
                pendingArchive = nil
            }
        } message: {
            Text(verbatim: "归档后，该问题不再参与未来 AI 分类、默认统计或默认导出；已有答案和理由会完整保留，且可随时恢复。")
        }
        .sheet(item: $purgeCandidate) { question in
            QuestionPermanentDeleteSheet(question: question) { receipt in
                app.toast = "已彻底删除「\(receipt.question.displayName)」。备份已创建：\(receipt.backupURL.lastPathComponent)"
                purgeCandidate = nil
            }
        }
        .sheet(isPresented: $showNewQuestion) {
            NewQuestionSheet()
        }
    }
}

// 单个分类问题的编辑器。文本改动走「草稿 + 显式保存」，已有答案时弹知情确认，
// 避免直接改文本把旧答案悄悄重解释成新问题的答案。
struct QuestionEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accentPalette) private var palette
    let id: String
    let onArchive: (Question) -> Void

    @State private var draft = ""
    @State private var loaded = false
    @State private var showGate = false
    @State private var showHistoricalBackfillConfirm = false

    private var question: Question? { app.config.classify.questions.first { $0.id == id } }

    var body: some View {
        if let q = question, let binding = app.questionBinding(id) {
            let dirty = draft != q.text
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("昵称（导出表头）", text: binding.nickname).textFieldStyle(.plain).lineLimit(1)
                        .padding(7).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: 220)
                    Spacer()
                    Text(verbatim: "标识 \(q.id)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Button {
                        onArchive(q)
                    } label: {
                        Label("归档", systemImage: "archivebox")
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .help("停止未来处理，保留历史答案与理由")
                }

                TextEditor(text: $draft)
                    .font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
                    .padding(6).frame(height: 80)
                    .background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))

                if dirty {
                    HStack(spacing: 8) {
                        Text("问题文本已修改").font(.system(size: 12)).foregroundStyle(Theme.amber)
                        Spacer()
                        Button("放弃") { draft = q.text }.buttonStyle(.bordered).controlSize(.small)
                        Button("保存修改") { trySave(q) }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(palette.accent)
                    }
                }

                HStack(spacing: 18) {
                    Toggle("AI 处理", isOn: binding.classify).toggleStyle(.checkbox)
                    Toggle("导出到 CSV", isOn: binding.export).toggleStyle(.checkbox)
                }.font(.system(size: 13)).foregroundStyle(Theme.fg)

                HStack(spacing: 8) {
                    Label("生效范围：\(q.coverage.label)", systemImage: q.coverage == .futureArticles ? "clock.arrow.circlepath" : "tray.full")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                    if q.coverage == .futureArticles {
                        Button("补答已有文章") { showHistoricalBackfillConfirm = true }
                            .buttonStyle(OutlineButtonStyle())
                            .help("让下一次智能分类也处理创建此问题前已在库中的文章")
                    }
                }
            }
            .padding(12)
            .background(Theme.panel2.opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear { if !loaded { draft = q.text; loaded = true } }
            .confirmationDialog("该问题已有答案，如何处理这次文本修改？", isPresented: $showGate, titleVisibility: .visible) {
                Button("新建为新问题（推荐）") {
                    app.replaceQuestionWithNew(oldId: id, newText: draft); draft = q.text
                }
                Button("就地修改并清空旧答案", role: .destructive) {
                    app.updateQuestionText(id, draft); app.clearQuestionAnswers(id)
                }
                Button("仅措辞微调，保留旧答案") { app.updateQuestionText(id, draft) }
                Button("取消", role: .cancel) {}
            } message: {
                Text(verbatim: "旧答案由改动前的问题文本产生。若标准变了，建议新建为新问题（旧问题会归档、保留作历史）；新问题默认只处理以后新文章。仅当是措辞微调时才保留旧答案。")
            }
            .confirmationDialog("为已有文章补答这个问题？", isPresented: $showHistoricalBackfillConfirm, titleVisibility: .visible) {
                Button("下次分类时补答全部历史文章") {
                    switch app.setQuestionCoverage(id, coverage: .allArticles) {
                    case .success:
                        app.toast = "已设为“全部已有与未来文章”；下次确认智能分类时会显示实际待处理数量。"
                    case .failure(let error):
                        app.toast = error.localizedDescription
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不会立即调用 AI；但下一次运行智能分类时，会为当前库中尚未回答的历史文章补答，可能消耗较多额度。")
            }
        }
    }

    private func trySave(_ q: Question) {
        if app.questionHasAnswers(id) { showGate = true }
        else { app.updateQuestionText(id, draft) }
    }
}

/// 新问题必须在创建前明确其覆盖范围，避免空白问题或“新增后悄悄扫描全库”的隐式行为。
private struct NewQuestionSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var text = ""
    @State private var coverage: QuestionCoverage = .futureArticles
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加分类问题")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.fg)

            VStack(alignment: .leading, spacing: 5) {
                Text("昵称（用于列表和导出表头）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                TextField("例如：目标疾病相关性", text: $nickname)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Theme.panel2)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("完整问题")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(height: 118)
                    .background(Theme.panel2)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("生效范围")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Picker("生效范围", selection: $coverage) {
                    ForEach(QuestionCoverage.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Text(coverage.explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(coverage == .futureArticles ? Theme.muted : Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Button("创建问题") { createQuestion() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 540, alignment: .leading)
        .background(Theme.panel)
    }

    private func createQuestion() {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            validationMessage = "请先填写完整问题；空问题不会被创建。"
            return
        }
        let id = app.addQuestion(
            nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
            text: cleanText,
            coverage: coverage
        )
        guard !id.isEmpty else {
            validationMessage = "创建失败：无法保存项目配置。"
            return
        }
        app.toast = coverage == .futureArticles
            ? "已添加问题「\(id)」：默认只处理以后新合并的文章。"
            : "已添加问题「\(id)」：下次智能分类会补答当前历史库。"
        dismiss()
    }
}

/// 历史问题默认收起在「已归档的问题」中。恢复只改生命周期标记；物理删除则另走
/// 输入 ID 的确认单，避免把“暂时不用”误做成不可逆的数据删除。
private struct ArchivedQuestionRow: View {
    @EnvironmentObject private var app: AppState
    let question: Question
    let requestPermanentDeletion: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    Text("标识 \(question.id) · 已归档 · \(question.coverage.shortLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Button("恢复") {
                    switch app.restoreArchivedQuestion(question.id) {
                    case .success(let restored):
                        app.toast = "已恢复「\(restored.displayName)」。"
                    case .failure(let error):
                        app.toast = error.localizedDescription
                    }
                }
                .buttonStyle(OutlineButtonStyle())

                Button("彻底删除") {
                    requestPermanentDeletion()
                }
                .buttonStyle(.bordered)
                .tint(Theme.red)
                .help("永久删除问题列与全部历史答案")
            }

            if !question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Text(question.classify ? "恢复后会继续参与 AI 分类。" : "恢复后仍保持“AI 处理”关闭。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .padding(11)
        .background(Theme.panel2.opacity(0.45))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 比普通 alert 多一层文字确认；只有归档项目可进入这里，且删除 API 会在写入前
/// 建立独立 SQLite 备份。失败状态留在单内，避免仅靠短暂 toast 丢失关键原因。
private struct QuestionPermanentDeleteSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    let question: Question
    let onDeleted: (QuestionDeletionReceipt) -> Void

    @State private var confirmationID = ""
    @State private var errorMessage: String?
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("彻底删除已归档问题", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.red)

            Text(verbatim: "将永久删除「\(question.displayName)」的 AI 问题、答案与理由列。删除前会在项目中创建独立数据库备份；这不能由“恢复”撤销。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("请输入问题标识「\(question.id)」以确认：")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.fg)
                TextField(question.id, text: $confirmationID)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Theme.panel2)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .textSelection(.enabled)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 8) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(isDeleting)
                Button {
                    deletePermanently()
                } label: {
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("永久删除问题")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.red)
                .disabled(confirmationID != question.id || isDeleting)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(Theme.panel)
    }

    private func deletePermanently() {
        guard confirmationID == question.id, !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        switch app.deleteQuestionPermanently(question.id) {
        case .success(let receipt):
            isDeleting = false
            onDeleted(receipt)
            dismiss()
        case .failure(let error):
            isDeleting = false
            errorMessage = error.localizedDescription
        }
    }
}

// ── AI 方案卡片：可保存多个方案，选择其一用于翻译与分类 ───────────────────────

struct AIProfilesCard: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accentPalette) private var palette
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
                        .foregroundStyle(active ? palette.accent : Theme.muted)
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
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? palette.accentLine.opacity(0.75) : Theme.line, lineWidth: 1))
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

import SwiftUI
import Foundation

private enum WizardStepDirection {
    case forward
    case backward
}

struct SetupWizardView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accentPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var stepDirection: WizardStepDirection = .forward
    @State private var journals = ""
    @State private var keywords = ""
    @State private var draftQuestions: [Question] = []
    @State private var nextDraftQuestionNumber = 1
    @State private var questionValidationMessage: String?
    @State private var expandedQuestionID: String?
    @State private var draftAIProfiles: [AIProfile] = []
    @State private var activeDraftAIID = ""
    @State private var expandedAIProfileID: String?
    @State private var testingProfileID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(palette.accent)
                    Text("首次设置").font(.system(size: 25, weight: .bold))
                }
                if let ws = app.workspace {
                    Text("项目：\(ws.root.path)").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }

                Card {
                    ZStack(alignment: .topLeading) {
                        Group {
                            if step == 0 {
                            wizardStepCard(
                                number: 1,
                                title: "检索范围",
                                primaryTitle: "下一步",
                                primaryAction: { moveToStep(1) }
                            ) {
                                VStack(alignment: .leading, spacing: 12) {
                                    retrievalEditorCard("期刊", text: $journals, height: 110)
                                    retrievalEditorCard("关键词检索式", text: $keywords, height: 90)
                                    Spacer(minLength: 0)
                                    guideRow(
                                        "检索范围设计指南",
                                        url: Docs.retrieval(anchor: "journals")
                                    )
                                }
                            }
                            } else if step == 1 {
                            wizardStepCard(
                                number: 2,
                                title: "筛选问题",
                                primaryTitle: "下一步",
                                backAction: { moveToStep(0) },
                                primaryAction: advanceFromQuestions
                            ) {
                                if canEditQuestionsInSetup {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack(spacing: 8) {
                                            Text(draftQuestions.isEmpty ? "未配置筛选问题" : "已配置 \(draftQuestions.count) 个问题")
                                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.fg)
                                            Spacer()
                                            Button(action: addDraftQuestion) {
                                                Label("新增问题", systemImage: "plus")
                                            }
                                            .buttonStyle(OutlineButtonStyle())
                                        }

                                        if draftQuestions.isEmpty {
                                            emptyCollectionState(
                                                title: "未配置筛选问题",
                                                message: "分类步骤将跳过。可在“配置”页新增问题。",
                                                symbol: "checklist"
                                            )
                                        } else {
                                            questionList
                                        }

                                        if let questionValidationMessage {
                                            Label(questionValidationMessage, systemImage: "exclamationmark.circle.fill")
                                                .font(.system(size: 12)).foregroundStyle(Theme.red)
                                        }

                                        Spacer(minLength: 0)
                                        guideRow(
                                            "筛选问题设计指南",
                                            url: Docs.retrieval(anchor: "questions")
                                        )
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 12) {
                                        existingQuestionSafetyNotice
                                        Spacer(minLength: 0)
                                        guideRow(
                                            "筛选问题设计指南",
                                            url: Docs.retrieval(anchor: "questions")
                                        )
                                    }
                                }
                            }
                            } else {
                            wizardStepCard(
                                number: 3,
                                title: "模型服务",
                                primaryTitle: "完成设置",
                                backAction: { moveToStep(1) },
                                primaryAction: finish
                            ) {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 8) {
                                        Text(aiProfilesStatus)
                                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.fg)
                                        Spacer()
                                        Button(action: addDraftAIProfile) {
                                            Label("新增服务", systemImage: "plus")
                                        }
                                        .buttonStyle(OutlineButtonStyle())
                                    }

                                    if draftAIProfiles.isEmpty {
                                        emptyCollectionState(
                                            title: "未配置模型服务",
                                            message: "使用翻译或分类前，可在“配置”页新增服务。",
                                            symbol: "network"
                                        )
                                    } else {
                                        aiProfileList
                                    }

                                    Spacer(minLength: 0)
                                    guideRow(
                                        "模型服务配置说明",
                                        url: Docs.setup(anchor: "ai")
                                    )
                                }
                            }
                            }
                        }
                        .id(step)
                        .transition(wizardStepTransition)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: 610)
                }

                Button("跳过") { app.route = .main }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(40)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            journals = app.readJournals()
            keywords = app.readKeywords()
            draftQuestions = app.config.classify.questions
            if canEditQuestionsInSetup {
                draftQuestions.removeAll(where: Templates.isLegacyDefaultFocusQuestion)
            }
            let largestID = draftQuestions.compactMap { question -> Int? in
                guard question.id.hasPrefix("q"), let n = Int(question.id.dropFirst()) else { return nil }
                return n
            }.max() ?? 0
            nextDraftQuestionNumber = max(app.config.classify.nextQuestionNumber, largestID + 1)
            expandedQuestionID = draftQuestions.first?.id
            let profiles = app.config.aiProfiles.isEmpty ? [AIProfile(name: "默认服务")] : app.config.aiProfiles
            draftAIProfiles = profiles
            activeDraftAIID = profiles.contains(where: { $0.id == app.config.activeAIID })
                ? app.config.activeAIID
                : (profiles.first?.id ?? "")
            expandedAIProfileID = activeDraftAIID
        }
    }

    /// 首设项目尚未建库，问题草稿可安全整体写入；已有数据库可能含答案，必须交给
    /// “配置”页的新增/归档/版本化流程处理，不能在向导里直接替换数组。
    private var canEditQuestionsInSetup: Bool {
        guard let workspace = app.workspace else { return true }
        return !FileManager.default.fileExists(atPath: workspace.dbPath.path)
    }

    private var wizardStepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let enteringX: CGFloat = stepDirection == .forward ? 16 : -16
        let leavingX: CGFloat = stepDirection == .forward ? -10 : 10
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: enteringX, y: 0)),
            removal: .opacity.combined(with: .offset(x: leavingX, y: 0))
        )
    }

    private func moveToStep(_ nextStep: Int) {
        guard nextStep != step else { return }
        stepDirection = nextStep > step ? .forward : .backward
        withAnimation(reduceMotion ? AppMotion.reduced : AppMotion.wizard) {
            step = nextStep
        }
    }

    @ViewBuilder
    private func wizardStepCard<Content: View>(
        number: Int,
        title: String,
        primaryTitle: String,
        backAction: (() -> Void)? = nil,
        primaryAction: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            wizardStepHeader(number: number, title: title)
                .padding(.bottom, 14)
            Divider().overlay(Theme.line)
            content()
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().overlay(Theme.line)
            HStack {
                if let backAction {
                    Button("上一步", action: backAction)
                        .buttonStyle(OutlineButtonStyle())
                }
                Spacer()
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 610)
    }

    private func wizardStepHeader(number: Int, title: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            SectionTitle(title)
            Spacer(minLength: 8)
            Text("步骤 \(number) / 3")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(minHeight: 28)
                .background(Theme.panel2)
                .clipShape(Capsule())
        }
        .frame(minHeight: 30)
    }

    private var questionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(draftQuestions.enumerated()), id: \.element.id) { index, question in
                        draftQuestionCard(index: index)
                            .id(question.id)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 380)
            .onChange(of: expandedQuestionID) { id in
                guard let id else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var aiProfileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(draftAIProfiles.enumerated()), id: \.element.id) { index, profile in
                        draftAIProfileCard(index: index)
                            .id(profile.id)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 380)
            .onChange(of: expandedAIProfileID) { id in
                guard let id else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var activeDraftAIProfile: AIProfile? {
        draftAIProfiles.first(where: { $0.id == activeDraftAIID })
    }

    private var aiProfilesStatus: String {
        guard !draftAIProfiles.isEmpty else { return "未配置模型服务" }
        let activeName = activeDraftAIProfile.map(profileDisplayName) ?? "未选择"
        return "已配置 \(draftAIProfiles.count) 个服务 · 当前：\(activeName)"
    }

    private func emptyCollectionState(title: String, message: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.fg)
            Text(message)
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Theme.panel2.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func guideRow(_ text: String, url: URL) -> some View {
        Button { Docs.open(url) } label: {
            HStack(spacing: 9) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text("查看\(text)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.fg)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(palette.accentSoft)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(palette.accentLine, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func testDraftAIProfile(_ profile: AIProfile) {
        testingProfileID = profile.id
        app.testAIConnection(profile.asConfig) { _, message in
            if testingProfileID == profile.id { testingProfileID = nil }
            app.toast = message
        }
    }

    private func finish() {
        var cfg = app.config
        let profiles = draftAIProfiles.map { profile -> AIProfile in
            var profile = profile
            profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.baseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.apiKey = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.extraParams = profile.extraParams.trimmingCharacters(in: .whitespacesAndNewlines)
            return profile
        }
        cfg.aiProfiles = profiles
        cfg.activeAIID = profiles.contains(where: { $0.id == activeDraftAIID })
            ? activeDraftAIID
            : (profiles.first?.id ?? "")
        if canEditQuestionsInSetup {
            cfg.classify.questions = draftQuestions
            cfg.classify.nextQuestionNumber = max(cfg.classify.nextQuestionNumber, nextDraftQuestionNumber)
            cfg.classify.normalizeQuestionIDAllocator()
        }
        app.saveConfig(cfg, journals: journals, keywords: keywords)
        app.route = .main
    }

    private func retrievalEditorCard(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.fg)
                .padding(12)
            Divider().overlay(Theme.line)
            LinedEditorField(text: text, height: height)
                .padding(14)
        }
        .background(Theme.panel2)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.accentLine, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var existingQuestionSafetyNotice: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("已保留现有筛选问题", systemImage: "lock.shield")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.fg)
            Text("为保护已有问题与答案，此处不可编辑。可在“配置 → 分类”中管理。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel2.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func draftAIProfileCard(index: Int) -> some View {
        let profile = draftAIProfiles[index]
        let isExpanded = expandedAIProfileID == profile.id
        let isActive = activeDraftAIID == profile.id

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Text("\(index + 1)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isExpanded ? palette.accentForeground : Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(isExpanded ? palette.accent : Theme.line.opacity(0.65))
                    .clipShape(Circle())

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        expandedAIProfileID = isExpanded ? nil : profile.id
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profileDisplayName(profile))
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.fg)
                        Text(profileSummary(profile))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isActive {
                    statusPill("当前服务", color: palette.accent)
                } else if !profile.isComplete {
                    statusPill("待填写", color: Theme.amber)
                }

                Button {
                    activeDraftAIID = profile.id
                } label: {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isActive ? palette.accent : Theme.muted)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .help(isActive ? "当前用于翻译与分类的服务" : "设为当前服务")
                .accessibilityLabel(isActive ? "当前服务" : "设为当前服务")

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                Button(role: .destructive) {
                    removeDraftAIProfile(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .help("首次设置期间移除的服务不会被保存。")
                .accessibilityLabel("移除服务 \(index + 1)")
            }
            .padding(12)

            if isExpanded {
                Divider().overlay(Theme.line)
                VStack(alignment: .leading, spacing: 8) {
                    profileFieldLabel("服务名称")
                    profileTextField("例如：主用模型服务", $draftAIProfiles[index].name)

                    profileFieldLabel("接口地址（Base URL）")
                    profileTextField("https://example.com/v1", $draftAIProfiles[index].baseURL)
                    Text(verbatim: "通常以 /v1 结尾；也可填写完整的 /chat/completions 路径。")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)

                    profileFieldLabel("模型名称")
                    profileTextField("例如：gpt-4.1-mini", $draftAIProfiles[index].model)

                    profileFieldLabel("API Key")
                    profileSecureField("按服务商要求填写", $draftAIProfiles[index].apiKey)

                    profileFieldLabel("额外请求参数（JSON，可选）")
                    profileTextField("例如：{\"reasoning_effort\": \"minimal\"}", $draftAIProfiles[index].extraParams)
                    Text(verbatim: "用于服务商特有开关；写错的键通常会由服务商忽略。")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)

                    Button(testingProfileID == profile.id ? "测试中…" : "测试连接") {
                        testDraftAIProfile(profile)
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(testingProfileID != nil)
                }
                .padding(.leading, 51)
                .padding(.trailing, 14)
                .padding(.vertical, 14)
            }
        }
        .background(isExpanded ? Theme.panel2 : Theme.control)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isExpanded ? palette.accentLine : Theme.surfaceLine.opacity(0.8), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(color.opacity(0.11))
            .clipShape(Capsule())
    }

    private func profileDisplayName(_ profile: AIProfile) -> String {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名服务" : name
    }

    private func profileSummary(_ profile: AIProfile) -> String {
        let baseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.isEmpty && model.isEmpty { return "接口地址与模型名称未填写" }
        if baseURL.isEmpty { return "接口地址未填写" }
        if model.isEmpty { return "模型名称未填写" }
        return "\(model) · \(baseURL)"
    }

    private func addDraftAIProfile() {
        var number = 1
        while draftAIProfiles.contains(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "服务 \(number)"
        }) {
            number += 1
        }
        let profile = AIProfile(name: "服务 \(number)")
        draftAIProfiles.append(profile)
        activeDraftAIID = profile.id
        expandedAIProfileID = profile.id
    }

    private func removeDraftAIProfile(at index: Int) {
        let id = draftAIProfiles[index].id
        let replacementID: String?
        if index + 1 < draftAIProfiles.count {
            replacementID = draftAIProfiles[index + 1].id
        } else if index > 0 {
            replacementID = draftAIProfiles[index - 1].id
        } else {
            replacementID = nil
        }
        draftAIProfiles.remove(at: index)
        if activeDraftAIID == id { activeDraftAIID = replacementID ?? "" }
        if expandedAIProfileID == id { expandedAIProfileID = replacementID }
        if testingProfileID == id { testingProfileID = nil }
    }

    @ViewBuilder private func profileFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
    }

    @ViewBuilder private func profileTextField(_ placeholder: String, _ binding: Binding<String>) -> some View {
        TextField(placeholder, text: binding)
            .font(.system(size: 14))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Theme.control)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private func profileSecureField(_ placeholder: String, _ binding: Binding<String>) -> some View {
        SecureField(placeholder, text: binding)
            .font(.system(size: 14))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Theme.control)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private func draftQuestionCard(index: Int) -> some View {
        let question = draftQuestions[index]
        let isExpanded = expandedQuestionID == question.id

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Text("\(index + 1)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isExpanded ? palette.accentForeground : Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(isExpanded ? palette.accent : Theme.line.opacity(0.65))
                    .clipShape(Circle())

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        expandedQuestionID = isExpanded ? nil : question.id
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(question.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "问题昵称未填写" : question.nickname)
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.fg)
                        Text(questionSummary(question.text))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if question.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    statusPill("待填写", color: Theme.amber)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                Button(role: .destructive) {
                    removeDraftQuestion(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .help("首次设置期间移除的问题不会被创建；已有项目的问题请在“配置”页归档。")
                .accessibilityLabel("移除问题 \(index + 1)")
            }
            .padding(12)

            if isExpanded {
                Divider().overlay(Theme.line)
                VStack(alignment: .leading, spacing: 8) {
                    questionFieldLabel("问题昵称")
                    questionTextField("例如：目标疾病相关性", $draftQuestions[index].nickname)

                    questionFieldLabel("问题内容")
                    questionTextEditor($draftQuestions[index].text)
                }
                .padding(.leading, 51)
                .padding(.trailing, 14)
                .padding(.vertical, 14)
            }
        }
        .background(isExpanded ? Theme.panel2 : Theme.control)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isExpanded ? palette.accentLine : Theme.surfaceLine.opacity(0.8), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func addDraftQuestion() {
        var number = nextDraftQuestionNumber
        while draftQuestions.contains(where: { $0.id == "q\(number)" }) {
            number += 1
        }
        let question = Question(id: "q\(number)", text: "")
        draftQuestions.append(question)
        nextDraftQuestionNumber = number + 1
        expandedQuestionID = question.id
        questionValidationMessage = nil
    }

    private func removeDraftQuestion(at index: Int) {
        let id = draftQuestions[index].id
        let nextExpandedID: String?
        if index + 1 < draftQuestions.count {
            nextExpandedID = draftQuestions[index + 1].id
        } else if index > 0 {
            nextExpandedID = draftQuestions[index - 1].id
        } else {
            nextExpandedID = nil
        }
        draftQuestions.remove(at: index)
        if expandedQuestionID == id {
            expandedQuestionID = nextExpandedID
        }
        questionValidationMessage = nil
    }

    @ViewBuilder private func questionFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
    }

    @ViewBuilder private func questionTextField(_ placeholder: String, _ binding: Binding<String>) -> some View {
        TextField(placeholder, text: binding)
            .font(.system(size: 14))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Theme.control)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private func questionTextEditor(_ binding: Binding<String>) -> some View {
        TextEditor(text: binding)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8).frame(height: 132)
            .background(Theme.control)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func questionSummary(_ text: String) -> String {
        let summary = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "问题内容未填写" : summary
    }

    private func advanceFromQuestions() {
        guard canEditQuestionsInSetup else {
            moveToStep(2)
            return
        }
        if let emptyNicknameIndex = draftQuestions.firstIndex(where: {
            $0.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            expandedQuestionID = draftQuestions[emptyNicknameIndex].id
            questionValidationMessage = "请填写问题 \(emptyNicknameIndex + 1) 的问题昵称。"
            return
        }
        if let emptyTextIndex = draftQuestions.firstIndex(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            expandedQuestionID = draftQuestions[emptyTextIndex].id
            questionValidationMessage = "请填写问题 \(emptyTextIndex + 1) 的问题内容。"
            return
        }

        for index in draftQuestions.indices {
            draftQuestions[index].nickname = draftQuestions[index].nickname
                .trimmingCharacters(in: .whitespacesAndNewlines)
            draftQuestions[index].text = draftQuestions[index].text
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        questionValidationMessage = nil
        moveToStep(2)
    }

}

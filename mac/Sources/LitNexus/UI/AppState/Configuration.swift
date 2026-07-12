import Foundation
import SwiftUI

/// 问题归档／永久删除的明确结果。界面应把失败原样呈现给用户，尤其是永久删除中
/// 已生成的备份路径，不能把异常静默吞掉。
struct QuestionDeletionReceipt {
    let question: Question
    let backupURL: URL
}

enum QuestionLifecycleError: Error, LocalizedError {
    case noWorkspace
    case questionNotFound(String)
    case configSaveFailed(String)
    case databaseOpenFailed(questionID: String, message: String)
    case backupFailed(questionID: String, message: String)
    case databaseDeleteFailed(questionID: String, backupURL: URL, configRestored: Bool, message: String)
    case metadataSyncFailed(questionID: String, message: String)

    var errorDescription: String? {
        switch self {
        case .noWorkspace:
            return "未打开项目，无法修改分类问题。"
        case .questionNotFound(let id):
            return "未找到分类问题 \(id)。"
        case .configSaveFailed(let message):
            return "保存问题配置失败：\(message)"
        case .databaseOpenFailed(let id, let message):
            return "无法打开数据库，问题 \(id) 没有删除：\(message)"
        case .backupFailed(let id, let message):
            return "未能为永久删除问题 \(id) 创建备份，数据库没有修改：\(message)"
        case .databaseDeleteFailed(let id, let backup, let restored, let message):
            let rollback = restored ? "已恢复原配置。" : "原配置恢复失败，请立即使用备份恢复。"
            return "删除问题 \(id) 的数据库列失败：\(message) 已保留备份 \(backup.lastPathComponent)。\(rollback)"
        case .metadataSyncFailed(let id, let message):
            return "问题 \(id) 的配置已保存，但数据库元数据同步失败：\(message)"
        }
    }
}

extension AppState {
    // ── AI 方案管理（增删选立即持久化）─────────────────────────────────────────

    @discardableResult
    func addAIProfile() -> String {
        let p = AIProfile(name: "方案 \(config.aiProfiles.count + 1)")
        config.aiProfiles.append(p)
        config.activeAIID = p.id
        persistConfig()
        return p.id
    }

    func updateAIProfile(_ profile: AIProfile) {
        if let i = config.aiProfiles.firstIndex(where: { $0.id == profile.id }) {
            config.aiProfiles[i] = profile
            persistConfig()
        }
    }

    func deleteAIProfile(_ id: String) {
        config.aiProfiles.removeAll { $0.id == id }
        if config.activeAIID == id { config.activeAIID = config.aiProfiles.first?.id ?? "" }
        persistConfig()
    }

    func selectAIProfile(_ id: String) {
        config.activeAIID = id
        persistConfig()
    }

    func persistConfig() {
        guard let ws = workspace else { return }
        try? ConfigStore.save(config, to: ws.configPath)
    }

    // ── 项目主题色（仅写配置，不触发数据库重开或统计刷新）──────────────────────

    /// 保存项目强调色。`nil` 恢复默认 teal；外观模式仍由本机 UserDefaults 单独管理。
    func setProjectAccentHue(_ hue: Double?) {
        var updated = config
        updated.theme.accentHue = ThemeConfig.normalizedAccentHue(hue)
        config = updated
        persistConfig()
    }

    /// 供原生 `ColorPicker` 使用：色盘只提交色相，灰阶选择不会覆盖现有主题色。
    func projectAccentColorBinding() -> Binding<Color> {
        Binding(
            get: { AccentPalette.editorColor(hue: self.config.theme.accentHue) },
            set: { color in
                guard let hue = AccentPalette.hue(from: color) else { return }
                self.setProjectAccentHue(hue)
            }
        )
    }

    // ── 分类问题管理（增删改即时持久化，仿 AI 方案）─────────────────────────────

    /// 创建一个全新的问题。默认只面向随后合并的新文章；这避免用户仅因新增一个
    /// 问题就在下一次常规流水线中无提示地补答整个历史库。
    @discardableResult
    func addQuestion(
        nickname: String = "",
        text: String = "",
        coverage: QuestionCoverage = .futureArticles
    ) -> String {
        var updated = config
        let id = updated.classify.allocateQuestionID()
        let frontier = coverage == .futureArticles ? captureQuestionFrontier() : nil
        updated.classify.questions.append(Question(
            id: id,
            nickname: nickname,
            text: text,
            classify: true,
            export: true,
            classifyAfterRowID: frontier
        ))
        guard saveQuestionConfig(updated) else { return "" }
        config = updated
        syncQuestionMetadata(updated, questionID: id)
        refreshStats()
        return id
    }

    /// 当前某问题的可写绑定（编辑即写内存并持久化）。
    func questionBinding(_ id: String) -> Binding<Question>? {
        guard let idx = config.classify.questions.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.config.classify.questions[idx] },
            set: { self.config.classify.questions[idx] = $0; self.persistConfig() }
        )
    }

    /// 该问题是否已有 AI 答案（决定改文本时是否需要知情确认）。
    func questionHasAnswers(_ id: String) -> Bool {
        guard let ws = workspace else { return false }
        return ((try? Database(path: ws.dbPath, config: config).answerCount(id)) ?? 0) > 0
    }

    /// 就地更新问题文本并持久化。
    func updateQuestionText(_ id: String, _ text: String) {
        guard let i = config.classify.questions.firstIndex(where: { $0.id == id }) else { return }
        config.classify.questions[i].text = text
        persistConfig()
        _ = syncQuestionMetadata(config, questionID: id)
    }

    /// 清空某问题的全部旧答案（改文本且语义变化时用，下次分类重跑）。
    func clearQuestionAnswers(_ id: String) {
        guard let ws = workspace else { return }
        try? Database(path: ws.dbPath, config: config).clearClassification(id)
        refreshStats()
    }

    /// 显式改变新问题的生效范围。切换到“全部文章”不会立刻调用 AI；它只是让下一次
    /// 用户确认过的分类步骤开始补答历史文章。切到“仅未来”会在此刻重新记录边界。
    @discardableResult
    func setQuestionCoverage(_ id: String, coverage: QuestionCoverage) -> Result<Question, QuestionLifecycleError> {
        guard let index = config.classify.questions.firstIndex(where: { $0.id == id }) else {
            return .failure(.questionNotFound(id))
        }
        guard workspace != nil else { return .failure(.noWorkspace) }

        var updated = config
        updated.classify.questions[index].classifyAfterRowID =
            coverage == .futureArticles ? captureQuestionFrontier() : nil
        guard saveQuestionConfig(updated) else {
            return .failure(.configSaveFailed("无法写入 litnexus.toml"))
        }
        config = updated
        let question = updated.classify.questions[index]
        if let error = syncQuestionMetadata(updated, questionID: id) {
            refreshStats()
            return .failure(.metadataSyncFailed(questionID: id, message: error.localizedDescription))
        }
        refreshStats()
        return .success(question)
    }

    /// 默认删除语义：归档。归档问题退出未来 AI 分类，但保留原本的 `classify` 开关、
    /// 已有答案、导出列和数据库元数据；恢复后可无损回到此前状态。
    @discardableResult
    func archiveQuestion(_ id: String) -> Result<Question, QuestionLifecycleError> {
        setQuestionArchived(id, archived: true)
    }

    /// 恢复一个已归档问题。恢复后是否参与 AI 分类仍由它自己的 `classify` 开关决定。
    @discardableResult
    func restoreArchivedQuestion(_ id: String) -> Result<Question, QuestionLifecycleError> {
        setQuestionArchived(id, archived: false)
    }

    @discardableResult
    func setQuestionArchived(_ id: String, archived: Bool) -> Result<Question, QuestionLifecycleError> {
        guard let index = config.classify.questions.firstIndex(where: { $0.id == id }) else {
            return .failure(.questionNotFound(id))
        }
        guard workspace != nil else { return .failure(.noWorkspace) }

        var updated = config
        updated.classify.questions[index].archived = archived
        guard saveQuestionConfig(updated) else {
            return .failure(.configSaveFailed("无法写入 litnexus.toml"))
        }

        // 配置是权威来源；即使元数据同步暂时失败，下次打开数据库仍会由
        // ensureDynamicColumns/writeQuestionMeta 补齐，因此不回滚已成功的归档配置。
        config = updated
        let question = updated.classify.questions[index]
        if let error = syncQuestionMetadata(updated, questionID: id) {
            refreshStats()
            return .failure(.metadataSyncFailed(questionID: id, message: error.localizedDescription))
        }
        refreshStats()
        return .success(question)
    }

    /// 退役旧问题（停用 AI 处理、保留列与数据作历史）+ 用新文本新建一个独立问题。
    func replaceQuestionWithNew(
        oldId: String,
        newText: String,
        coverage: QuestionCoverage = .futureArticles
    ) {
        guard let oldIndex = config.classify.questions.firstIndex(where: { $0.id == oldId }) else {
            toast = QuestionLifecycleError.questionNotFound(oldId).localizedDescription
            return
        }
        var updated = config
        let nickname = updated.classify.questions[oldIndex].nickname
        // 新文本属于新问题版本：旧问题默认归档，而不是偷改它的「AI 处理」偏好。
        updated.classify.questions[oldIndex].archived = true
        let newId = updated.classify.allocateQuestionID()
        let frontier = coverage == .futureArticles ? captureQuestionFrontier() : nil
        updated.classify.questions.append(Question(
            id: newId,
            nickname: nickname,
            text: newText,
            classify: true,
            export: true,
            classifyAfterRowID: frontier
        ))
        guard saveQuestionConfig(updated) else { return }
        config = updated
        syncQuestionMetadata(updated, questionID: newId)
        refreshStats()
    }

    /// 永久删除问题：先做独立 SQLite 备份，再从数据库 DROP 掉问题列。
    ///
    /// 这是唯一会物理删除历史答案的 API。失败会通过 Result 返回明确错误（含备份路径），
    /// 不允许静默吞掉；调用界面必须显示该错误，成功时也应告知备份文件位置。
    @discardableResult
    func deleteQuestionPermanently(_ id: String) -> Result<QuestionDeletionReceipt, QuestionLifecycleError> {
        do { return .success(try permanentlyDeleteQuestion(id)) }
        catch let error as QuestionLifecycleError { return .failure(error) }
        catch { return .failure(.configSaveFailed(error.localizedDescription)) }
    }

    /// `deleteQuestionPermanently` 的 throwing 版本，供未来命令行／可测试调用方使用。
    func permanentlyDeleteQuestion(_ id: String) throws -> QuestionDeletionReceipt {
        guard let ws = workspace else { throw QuestionLifecycleError.noWorkspace }
        guard let index = config.classify.questions.firstIndex(where: { $0.id == id }) else {
            throw QuestionLifecycleError.questionNotFound(id)
        }

        let oldConfig = config
        let removed = oldConfig.classify.questions[index]
        var updated = oldConfig
        updated.classify.questions.remove(at: index)
        // 高水位绝不向后退：即使删除最高编号的问题，新问题也不会复用它的 id。
        updated.classify.normalizeQuestionIDAllocator()

        let db: Database
        do {
            db = try Database(path: ws.dbPath, config: oldConfig)
        } catch {
            throw QuestionLifecycleError.databaseOpenFailed(questionID: id, message: error.localizedDescription)
        }
        let backup: URL
        do {
            backup = try db.backupBeforeQuestionDeletion(id)
        } catch {
            throw QuestionLifecycleError.backupFailed(questionID: id, message: error.localizedDescription)
        }

        // 先让配置原子写入新状态，再执行 SQLite 事务。若 SQLite 拒绝 DROP COLUMN，
        // 立即恢复原配置；数据库事务自身也会回滚，且备份始终保留。
        do {
            try ConfigStore.save(updated, to: ws.configPath)
        } catch {
            throw QuestionLifecycleError.configSaveFailed(error.localizedDescription)
        }
        do {
            try db.dropQuestionColumns(id)
        } catch {
            let restoreSucceeded: Bool
            do {
                try ConfigStore.save(oldConfig, to: ws.configPath)
                restoreSucceeded = true
            } catch {
                restoreSucceeded = false
            }
            throw QuestionLifecycleError.databaseDeleteFailed(
                questionID: id, backupURL: backup,
                configRestored: restoreSucceeded, message: error.localizedDescription)
        }

        config = updated
        refreshStats()
        return QuestionDeletionReceipt(question: removed, backupURL: backup)
    }

    /// 保存问题配置时不使用通用 `persistConfig()`：后者为了普通即时编辑而吞错误，
    /// 但问题生命周期改变需要把失败交给调用方。
    private func saveQuestionConfig(_ updated: AppConfig) -> Bool {
        guard let ws = workspace else {
            toast = QuestionLifecycleError.noWorkspace.localizedDescription
            return false
        }
        do {
            try ConfigStore.save(updated, to: ws.configPath)
            return true
        } catch {
            toast = QuestionLifecycleError.configSaveFailed(error.localizedDescription).localizedDescription
            return false
        }
    }

    /// 读取当前 articles 的 rowid 前沿，供“仅以后新文章”问题作为稳定边界。若数据库
    /// 尚不存在或暂时不可读，安全默认 0：它不会把任何已有正 rowid 的文章算进未来范围。
    private func captureQuestionFrontier() -> Int {
        guard let ws = workspace else { return 0 }
        return (try? Database(path: ws.dbPath, config: config).currentArticleRowID()) ?? 0
    }

    /// 数据库尚未创建时无需为了归档单独建库；它以后首次打开时会自动同步元数据。
    /// 返回可展示的错误，而不把异常静默忽略。
    @discardableResult
    private func syncQuestionMetadata(_ updated: AppConfig, questionID: String) -> Error? {
        guard let ws = workspace,
              FileManager.default.fileExists(atPath: ws.dbPath.path) else { return nil }
        do {
            _ = try Database(path: ws.dbPath, config: updated)
            return nil
        } catch {
            toast = QuestionLifecycleError.metadataSyncFailed(
                questionID: questionID, message: error.localizedDescription).localizedDescription
            return error
        }
    }

    /// 当前选中方案的可写绑定（编辑即写入内存并持久化）。
    func activeProfileBinding() -> Binding<AIProfile>? {
        guard let idx = config.aiProfiles.firstIndex(where: { $0.id == config.activeAIID }) else { return nil }
        return Binding(
            get: { self.config.aiProfiles[idx] },
            set: { self.config.aiProfiles[idx] = $0; self.persistConfig() }
        )
    }

    // ── 保存配置 + 检索列表 ─────────────────────────────────────────────────────

    /// 自动保存设置与检索列表（静默，不弹提示）。期刊/关键词现统一存进 litnexus.toml。
    func saveConfig(_ cfg: AppConfig, journals: String, keywords: String) {
        guard let ws = workspace else { return }
        var c = cfg
        c.download.journals = journals.components(separatedBy: "\n")
        c.download.keywords = keywords.components(separatedBy: "\n")
        do {
            try ConfigStore.save(c, to: ws.configPath)
            _ = try Database(path: ws.dbPath, config: c)  // 补齐动态列
            config = c
            refreshStats()
        } catch {
            toast = "保存失败：\(error.localizedDescription)"
        }
    }

    func readJournals() -> String { config.download.journals.joined(separator: "\n") }
    func readKeywords() -> String { config.download.keywords.joined(separator: "\n") }

    // ── 测试 AI 连接 ────────────────────────────────────────────────────────────

    func testAIConnection(_ ai: AIConfig, completion: @escaping (Bool, String) -> Void) {
        guard !ai.apiKey.isEmpty else { completion(false, "请填写 API Key"); return }
        guard !ai.baseURL.isEmpty, !ai.model.isEmpty else { completion(false, "请填写接口地址与模型名称"); return }
        DispatchQueue.global().async {
            do {
                _ = try AIClient.chat(ai: ai, system: "ping", user: "ping", temperature: 0)
                DispatchQueue.main.async { completion(true, "连接成功") }
            } catch {
                DispatchQueue.main.async { completion(false, "连接失败：\(error.localizedDescription)") }
            }
        }
    }
}

import Foundation

// Workspace lifecycle behavior for AppState.

extension AppState {
    // ── 工作区 ────────────────────────────────────────────────────────────────

    func openOrCreate(_ url: URL) {
        let url = url.standardizedFileURL
        let fm = FileManager.default
        let probe = Workspace(root: url)

        // 1) 已有工作区（litnexus.toml 在）：直接打开，不触碰其内容
        if probe.isInitialized {
            WorkspaceStore.setActive(probe.root)
            applyWorkspace(probe)
            return
        }

        // 2) 不是文件夹（手输路径指向了文件）：拒绝
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists && !isDir.boolValue {
            toast = "所选路径不是文件夹：\(url.path)"
            return
        }

        // 3) 不存在 或 存在且为空：就地新建/初始化
        let isEmpty = (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty ?? true
        if !exists || isEmpty {
            do {
                let ws = try WorkspaceStore.create(url)
                applyWorkspace(ws)
                toast = exists ? "已在 \(url.lastPathComponent) 初始化新工作区" : "已新建工作区：\(url.lastPathComponent)"
            } catch {
                toast = "无法创建项目：\(error.localizedDescription)"
            }
            return
        }

        // 4) 非空且不是工作区：交给用户决定（默认在其中新建子文件夹）
        pendingInit = PendingWorkspaceInit(parent: url, isDangerous: WorkspaceStore.isDangerousPath(url))
    }

    // 初始化确认 sheet 的回调 ──────────────────────────────────────────────────

    /// 在所选文件夹下新建子文件夹作为工作区。
    func confirmInitNewSubfolder(_ name: String) {
        guard let p = pendingInit else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let final = trimmed.isEmpty ? "LitNexusDB" : trimmed
        let target = p.parent.appendingPathComponent(WorkspaceStore.uniquedSubfolderName(final, in: p.parent))
        do {
            let ws = try WorkspaceStore.create(target)
            applyWorkspace(ws)
            toast = "已新建工作区：\(target.lastPathComponent)"
        } catch {
            toast = "无法创建项目：\(error.localizedDescription)"
        }
        pendingInit = nil
    }

    /// 直接在所选文件夹就地初始化（危险路径不允许）。
    func confirmInitUseDirect() {
        guard let p = pendingInit, !p.isDangerous else { pendingInit = nil; return }
        do {
            let ws = try WorkspaceStore.create(p.parent)
            applyWorkspace(ws)
            toast = "已就地初始化工作区：\(p.parent.lastPathComponent)"
        } catch {
            toast = "无法初始化：\(error.localizedDescription)"
        }
        pendingInit = nil
    }

    func cancelInit() { pendingInit = nil }

    /// 打开/初始化工作区后的统一收尾。
    private func applyWorkspace(_ ws: Workspace) {
        workspace = ws
        config = (try? ConfigStore.load(ws.configPath)) ?? AppConfig()
        route = needsSetup ? .setup : .main
        page = .run
        runRecords = []
        logLines = []
        downloadDays = config.download.days
        resetSteps()
        refreshStats()
    }

    // Kept module-internal because AppState's initializer lives in its root file.
    func openExisting(_ ws: Workspace) {
        workspace = ws
        config = (try? ConfigStore.load(ws.configPath)) ?? AppConfig()
        route = needsSetup ? .setup : .main
        runRecords = []
        logLines = []
        downloadDays = config.download.days
        refreshStats()
    }

    func switchProject() {
        invalidateStatsCache()
        workspace = nil
        route = .chooser
        runRecords = []
        logLines = []
        stats = [:]
    }

    func finishSetup() {
        route = needsSetup ? .setup : .main
        refreshStats()
    }

    // ── 概览统计 ──────────────────────────────────────────────────────────────

    func refreshStats() {
        // 所有现有写后路径都会调用这里；先让统计页的内存快照失效，再复用
        // `computeStats` 的基础聚合，避免数据页和统计页各自重复查询数据库。
        invalidateStatsCache()
        guard workspace != nil else {
            stats = [:]; return
        }
        computeStats { [weak self] bundle in
            self?.stats = bundle?.overview ?? [:]
        }
    }
}

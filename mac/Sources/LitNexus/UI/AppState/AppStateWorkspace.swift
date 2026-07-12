import Foundation

// Workspace lifecycle behavior for AppState.

extension AppState {
    // ── 工作区 ────────────────────────────────────────────────────────────────

    func openOrCreate(_ url: URL) {
        do {
            let ws = try WorkspaceStore.create(url)
            workspace = ws
            config = (try? ConfigStore.load(ws.configPath)) ?? AppConfig()
            route = needsSetup ? .setup : .main
            page = .run
            runRecords = []
            logLines = []
            downloadDays = config.download.days
            resetSteps()
            refreshStats()
        } catch {
            toast = "无法打开项目：\(error.localizedDescription)"
        }
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

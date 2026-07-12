import Foundation
import TOMLKit

// 工作区（vault）：自包含目录，存放全部用户数据。
// 唯一在工作区外的状态是 state.toml（记录 active / recent），放系统配置目录。

struct Workspace: Equatable {
    let root: URL

    var configPath: URL { root.appendingPathComponent("litnexus.toml") }
    var dbPath: URL { root.appendingPathComponent("litnexus.db") }
    var downloadsDir: URL { root.appendingPathComponent("downloads") }
    var exportsDir: URL { root.appendingPathComponent("exports") }
    var journalsFile: URL { root.appendingPathComponent("journals.txt") }

    /// 根目录的 keywords.txt，外加可选 keywords/ 目录下所有 .txt。
    var keywordsFiles: [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        let single = root.appendingPathComponent("keywords.txt")
        if fm.fileExists(atPath: single.path) { files.append(single) }
        let kwDir = root.appendingPathComponent("keywords")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: kwDir.path, isDirectory: &isDir), isDir.boolValue,
           let items = try? fm.contentsOfDirectory(at: kwDir, includingPropertiesForKeys: nil) {
            files.append(contentsOf: items.filter { $0.pathExtension == "txt" }.sorted { $0.path < $1.path })
        }
        return files.isEmpty ? [single] : files
    }

    var isInitialized: Bool { FileManager.default.fileExists(atPath: configPath.path) }

    func ensureDirs() throws {
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
    }
}

enum WorkspaceError: Error, LocalizedError {
    case notFound
    case notInitialized(URL)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "未找到工作区。请新建或打开一个项目文件夹。"
        case .notInitialized(let url):
            return "工作区未初始化：\(url.path)（缺少 litnexus.toml）。"
        }
    }
}

enum WorkspaceStore {
    static let appName = "litnexus"
    static let envVar = "LITNEXUS_WORKSPACE"
    static let maxRecent = 10

    static var stateDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName)
    }
    static var stateFile: URL { stateDir.appendingPathComponent("state.toml") }

    // ── state.toml 读写（active / recent）──────────────────────────────────────

    private static func readState() -> (active: String?, recent: [String]) {
        guard let content = try? String(contentsOf: stateFile, encoding: .utf8),
              let table = try? TOMLTable(string: content) else {
            return (nil, [])
        }
        let active = table["active"]?.tomlValue.string
        let recent = table["recent"]?.tomlValue.array?.compactMap { $0.tomlValue.string } ?? []
        return (active, recent)
    }

    private static func writeState(active: String?, recent: [String]) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let root = TOMLTable()
        if let active { root["active"] = active }
        let arr = TOMLArray()
        for r in recent { arr.append(r) }
        root["recent"] = arr
        try? root.convert().write(to: stateFile, atomically: true, encoding: .utf8)
    }

    static func getActive() -> URL? {
        guard let p = readState().active else { return nil }
        return URL(fileURLWithPath: p)
    }

    static func listRecent() -> [URL] {
        readState().recent.map { URL(fileURLWithPath: $0) }
    }

    static func setActive(_ root: URL) {
        let resolved = root.standardizedFileURL.path
        let state = readState()
        var recent = [resolved] + state.recent.filter { $0 != resolved }
        if recent.count > maxRecent { recent = Array(recent.prefix(maxRecent)) }
        writeState(active: resolved, recent: recent)
    }

    // ── 解析 / 创建 ─────────────────────────────────────────────────────────────

    static func resolve(explicit: URL? = nil) throws -> Workspace {
        let candidate: URL?
        if let explicit {
            candidate = explicit
        } else if let env = ProcessInfo.processInfo.environment[envVar], !env.isEmpty {
            candidate = URL(fileURLWithPath: env)
        } else {
            candidate = getActive()
        }
        guard let candidate else { throw WorkspaceError.notFound }
        let ws = Workspace(root: candidate.standardizedFileURL)
        guard ws.isInitialized else { throw WorkspaceError.notInitialized(ws.root) }
        return ws
    }

    /// 在 root 创建工作区：建目录、写模板、（可选）设为活动。已存在的文件默认保留。
    @discardableResult
    static func create(_ root: URL, force: Bool = false, makeActive: Bool = true) throws -> Workspace {
        let ws = Workspace(root: root.standardizedFileURL)
        try FileManager.default.createDirectory(at: ws.root, withIntermediateDirectories: true)
        try ws.ensureDirs()

        // 期刊/关键词默认值已并入 AppConfig（写进 litnexus.toml），不再单独写 .txt。
        if force || !FileManager.default.fileExists(atPath: ws.configPath.path) {
            try ConfigStore.save(AppConfig(), to: ws.configPath)
        }

        if makeActive { setActive(ws.root) }
        return ws
    }
}

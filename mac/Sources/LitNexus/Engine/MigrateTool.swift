import Foundation

// 一次性迁移：把旧格式 .db（只读）导入一个全新临时工作区（默认 schema），
// 再导出为新格式独立 .db。用于把历史库接续到新软件。
//   swift run LitNexus migrate <oldDB> <outDB>

enum MigrateTool {
    static func run(oldDB: String, outDB: String) {
        let old = URL(fileURLWithPath: (oldDB as NSString).expandingTildeInPath)
        let out = URL(fileURLWithPath: (outDB as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: old.path) else {
            print("✗ 旧库不存在：\(old.path)"); exit(1)
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("litnexus_migrate_\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            // 全新工作区（不设为活动），默认配置 → q1/q2 + include/tags 列齐备
            let ws = try WorkspaceStore.create(tmp, makeActive: false)
            let cfg = try ConfigStore.load(ws.configPath)
            let db = try Database(path: ws.dbPath, config: cfg)

            print("→ 导入旧库：\(old.path)")
            let (ins, skip, total) = try db.importFromDatabase(old)
            print("  源库 \(total) 篇 → 新增 \(ins)，跳过 \(skip)")

            try db.exportTo(out)
            let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? nil
            let mb = size.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "?"
            print("✓ 已导出新格式库：\(out.path)（\(mb)）")
            exit(0)
        } catch {
            print("✗ 迁移失败：\(error)")
            exit(1)
        }
    }
}

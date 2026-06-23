import Foundation

// 临时诊断：用本项目的 CSV.parseWithHeader 解析指定文件，报告行数/列数错位/include 分布。
//   swift run LitNexus csvtest <path>
enum CSVTest {
    static func run(path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("✗ 读不了文件"); exit(1)
        }
        let (header, rows) = CSV.parseWithHeader(text)
        print("列数: \(header.count)")
        print("include 位置: \(header.firstIndex(of: "include").map(String.init) ?? "无")")
        print("数据行数: \(rows.count)")
        var inc: [String: Int] = [:]
        var bad = 0
        for r in rows {
            if r.count != header.count { bad += 1 }
            let v = (r["include"] ?? "").trimmingCharacters(in: .whitespaces)
            let key = v.count <= 15 ? v : String(v.prefix(15)) + "…"
            inc[key, default: 0] += 1
        }
        print("字段数≠表头的行: \(bad)")
        print("include 值分布(前12):")
        for (k, c) in inc.sorted(by: { $0.value > $1.value }).prefix(12) {
            print(String(format: "  %7d  %@", c, "\(k)"))
        }
        exit(0)
    }
}

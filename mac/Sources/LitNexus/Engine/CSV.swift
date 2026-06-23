import Foundation

// 极简 RFC4180 CSV 读写，匹配 Python csv 模块的行为（导出用 utf-8-sig，Excel 可直接打开）。

enum CSV {
    /// 把若干字符串行写成 CSV 文本（不含 BOM）。
    static func write(_ rows: [[String]]) -> String {
        rows.map { row in row.map(escapeField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private static func escapeField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// 解析 CSV 文本为若干行（每行是字段数组）。宽容容错，对齐 Python csv 的非严格行为：
    /// 仅当 `"` 出现在字段起始时才视为引号字段；字段中部的 `"`、以及引号字段内未配对的 `"`
    /// 都当作字面量，绝不因一个野引号而把后续整段吞掉（这正是之前导入错位丢标注的根因）。
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var fieldStart = true   // 当前是否处于字段起始位置
        // 按 Unicode 标量切分：Swift 会把 "\r\n" 当成单个 Character（grapheme）。
        let chars = text.unicodeScalars.map { Character($0) }
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    let next: Character? = i + 1 < n ? chars[i + 1] : nil
                    if next == "\"" {
                        field.append("\""); i += 1               // 转义引号 "" → "
                    } else if next == nil || next == "," || next == "\n" || next == "\r" {
                        inQuotes = false                          // 正常闭合
                    } else {
                        field.append("\"")                        // 宽容：字段内孤立引号当字面量
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    if fieldStart { inQuotes = true; fieldStart = false }
                    else { field.append("\"") }                   // 字段中部的引号当字面量
                case ",":
                    record.append(field); field = ""; fieldStart = true
                case "\n":
                    record.append(field); field = ""
                    rows.append(record); record = []; fieldStart = true
                case "\r":
                    break  // 跳过，\r\n 的 \n 会触发换行
                default:
                    field.append(c); fieldStart = false
                }
            }
            i += 1
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            rows.append(record)
        }
        return rows
    }

    /// 解析为带表头的字典数组（DictReader 等价）。自动去掉 utf-8-sig BOM。
    static func parseWithHeader(_ text: String) -> (header: [String], rows: [[String: String]]) {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        let all = parse(t)
        guard let header = all.first else { return ([], []) }
        let rows = all.dropFirst().map { fields -> [String: String] in
            var dict: [String: String] = [:]
            for (i, name) in header.enumerated() where i < fields.count {
                dict[name] = fields[i]
            }
            return dict
        }
        return (header, Array(rows))
    }
}

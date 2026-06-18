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

    /// 解析 CSV 文本为若干行（每行是字段数组）。处理引号包裹、转义引号、字段内换行。
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        // 按 Unicode 标量切分：Swift 会把 "\r\n" 当成单个 Character（grapheme），
        // 直接按 Character 遍历会导致换行匹配不到，故逐标量转成独立 Character。
        let chars = text.unicodeScalars.map { Character($0) }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\""); i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": record.append(field); field = ""
                case "\n":
                    record.append(field); field = ""
                    rows.append(record); record = []
                case "\r":
                    break  // 跳过，\r\n 的 \n 会触发换行
                default: field.append(c)
                }
            }
            i += 1
        }
        // 收尾最后一个字段/记录（文件末尾无换行时）
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

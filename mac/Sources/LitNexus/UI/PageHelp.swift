import SwiftUI
import AppKit

/// 主页面的帮助内容与文档站 `guide/page-help.md` 保持同一产品契约。
/// 浮层只给完成当前任务所需的信息；完整说明由用户主动在浏览器打开。
struct PageGuide: Equatable {
    let title: String
    let hoverSummary: String
    let purpose: String
    let steps: [String]
    let note: String
}

enum PageGuides {
    static let run = PageGuide(
        title: "运行",
        hoverSummary: "了解运行页的步骤、确认与记录。",
        purpose: "按顺序下载、合并、翻译与分类；也可以从更多操作中单独运行某一步。",
        steps: [
            "设定抓取范围与时间窗口。",
            "选择“开始运行”；AI 步骤会在首次运行前确认。",
            "在执行路径查看状态、数量、耗时与警告。",
        ],
        note: "下载只生成原始文件；合并后才会写入数据库。"
    )

    static let data = PageGuide(
        title: "数据",
        hoverSummary: "了解 CSV 复筛、导入导出和数据库备份。",
        purpose: "查看库内状态，导出 CSV 供人工复筛，导回应答，并管理数据库备份或导入。",
        steps: [
            "按需要选择导出范围与列；epmc_id、include、tags 会保留。",
            "在表格软件中只填写 include（yes/no）和可选 tags。",
            "选择 CSV 后先阅读预检，再确认写入人工标注。",
        ],
        note: "导入只按 epmc_id 匹配，只读取 include/tags；其他列即使改动也不会写回。"
    )

    static let stats = PageGuide(
        title: "统计",
        hoverSummary: "了解基础分布、按需洞察与卡片布局。",
        purpose: "总览始终显示；年代和完整期刊集合用于日常查看，其余分析只在需要时展开读取。",
        steps: [
            "切换“人工复筛结果”或“问题 · …”，图例会同步只显示当前图中的类别。",
            "在期刊分布中搜索完整集合，并点击任一列表头按该列排序。",
            "用右上角“编辑”拖动独立卡片调整顺序；展开状态会保存在本机。",
        ],
        note: "刷新不会重新下载文献或调用 AI；高级卡片只读取统计数据，结论仍应结合足够的人工复筛样本判断。"
    )

    static let settings = PageGuide(
        title: "配置",
        hoverSummary: "了解项目设置、AI 方案与主题色的保存方式。",
        purpose: "管理检索列表、AI 方案、翻译与分类参数、项目外观和高级数据结构。",
        steps: [
            "从上方分类切换到需要的设置区域。",
            "大多数修改会自动保存到当前项目。",
            "新增问题时选择仅未来文章或补答历史文章；修改旧问题前阅读确认选项。",
        ],
        note: "归档问题会退出未来分类、默认统计和导出，但不会删除历史答案。"
    )
}

struct PageHelpButton: View {
    let guide: PageGuide
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.panel2.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(guide.hoverSummary)
        .accessibilityLabel("\(guide.title)页面帮助")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PageHelpPopover(guide: guide)
        }
    }
}

/// 页面内的短帮助：用于解释一个字段或一次操作的最低必要规则。
/// 它刻意不放外链，避免用户在正在执行的工作流中被带离当前页面。
struct InlineHelpButton: View {
    let title: String
    let text: String
    var width: CGFloat = 300

    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(title)
        .accessibilityLabel(title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: width, alignment: .leading)
            .background(Theme.panel)
        }
    }
}

private struct PageHelpPopover: View {
    @Environment(\.accentPalette) private var palette
    let guide: PageGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(palette.accent)
                Text("\(guide.title)说明")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.fg)
            }

            Text(guide.purpose)
                .font(.system(size: 13))
                .foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(Theme.panel2))
                        Text(step)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Label(guide.note, systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.line)

            Button("打开完整说明") {
                guard let url = URL(string: "https://kiancai.github.io/LitNexus/guide/page-help/") else { return }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(OutlineButtonStyle())
            // 弹出帮助时不把键盘焦点自动落在这个次级链接上，避免出现突兀的系统蓝色焦点框。
            .focusable(false)
        }
        .padding(18)
        .frame(width: 330, alignment: .leading)
        .background(Theme.panel)
    }
}

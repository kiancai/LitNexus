import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var app: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarContent()
                .navigationSplitViewColumnWidth(min: 196, ideal: 218, max: 280)
        } detail: {
            ZStack {
                Theme.canvas
                switch app.page {
                case .run: RunView()
                case .data: DataView()
                case .stats: StatsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            // macOS 13 的 NavigationSplitView 会偶尔把默认侧栏切换按钮留为首个键盘焦点，
            // 从而显示一圈持久蓝框。清除首次残留焦点，不影响该按钮日后的正常使用。
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }
}

// 自定义侧边栏将路由状态映射为安静的 teal 选中态，避免 macOS 默认蓝色
// 与产品强调色冲突。每个项目保留原有的路由、标签与操作。
struct SidebarContent: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accentPalette) private var palette
    @State private var hoveredPage: Page?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand

            VStack(alignment: .leading, spacing: 4) {
                Text("工作区")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .textCase(.uppercase)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                ForEach(Page.allCases, id: \.self) { page in
                    navigationItem(for: page)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 16)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            BrandMark(size: 32)

            Text("LitNexus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.fg)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }

    private func navigationItem(for page: Page) -> some View {
        let selected = app.page == page
        let hovered = hoveredPage == page

        return Button {
            app.page = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .frame(width: 18)
                Text(page.rawValue)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.fg : Theme.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? palette.accentSoft : (hovered ? Theme.panel2.opacity(0.65) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? palette.accentLine.opacity(0.7) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering in
            hoveredPage = isHovering ? page : nil
        }
    }

    @ViewBuilder private var footer: some View {
        if let ws = app.workspace {
            VStack(alignment: .leading, spacing: 12) {
                Rectangle()
                    .fill(Theme.line.opacity(0.9))
                    .frame(height: 1)

                HStack(spacing: 9) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.accentSoft))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前项目")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                        Text(ws.root.lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                HStack(spacing: 7) {
                    Button { revealInFinder(ws.root) } label: {
                        Label("目录", systemImage: "folder")
                    }
                    .help("在 Finder 中打开项目目录")
                    Button { app.switchProject() } label: {
                        Label("切换", systemImage: "arrow.left.arrow.right")
                    }
                    .help("切换到其他项目")
                }
                .buttonStyle(SidebarActionButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

}

/// 品牌图形优先从已打包的 PNG 读取；直接 `swift run` 开发时仍保留一个可辨识的矢量兜底。
private struct BrandMark: View {
    @Environment(\.accentPalette) private var palette
    let size: CGFloat

    var body: some View {
        Group {
            if let image = BrandAsset.mark {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(palette.accentSoft)
                    .overlay(
                        Image(systemName: "link")
                            .font(.system(size: size * 0.48, weight: .bold))
                            .foregroundStyle(palette.accent)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}

private enum BrandAsset {
    static let mark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "litnexus-mark", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

private struct SidebarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.panel2 : Theme.control.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Theme.line.opacity(0.9), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// 各页通用容器：由容器统一计算版心，而不是交给每页内容的理想宽度决定。
// 因此所有页面的标题、卡片与页面边缘始终落在同一条对齐线上。
struct PageContainer<Content: View>: View {
    var maxWidth: CGFloat = 840
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            // 两侧固定保留 36pt；窗口再窄时也避免出现负宽度。
            let columnWidth = max(1, min(maxWidth, proxy.size.width - 72))
            // 不用 `frame(maxWidth: .infinity)` 再居中：macOS 在纵向滚动条出现时会缩窄
            // ScrollView 的内部可视宽度，导致整列内容向左跳几 pt。这里依据外层 GeometryReader
            // 固定左右留白，因此加载、折叠或刷新改变页面高度时，卡片的 x 坐标保持不变。
            let sideInset = max(36, (proxy.size.width - columnWidth) / 2)

            ScrollView {
                content
                    .frame(width: columnWidth, alignment: .topLeading)
                    .padding(.leading, sideInset)
                    .padding(.trailing, sideInset)
                    .padding(.top, 36)
                    .padding(.bottom, 56)
            }
            .background(Theme.canvas)
        }
    }
}

// 各页通用的标题区。
struct PageHeader: View {
    @Environment(\.accentPalette) private var palette
    let title: String
    let guide: PageGuide?
    let symbol: String?

    init(title: String, guide: PageGuide? = nil, symbol: String? = nil) {
        self.title = title
        self.guide = guide
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 29, weight: .bold))
                .tracking(-0.35)
                .foregroundStyle(Theme.fg)
            if let guide {
                PageHelpButton(guide: guide)
            }
        }
        .padding(.bottom, 2)
    }
}

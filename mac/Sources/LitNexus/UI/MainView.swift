import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pageOpacity = 1.0
    @State private var pageOffset: CGFloat = 0
    @State private var pendingPage: Page?
    @State private var navigationTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarContent(onSelect: selectPage)
                .navigationSplitViewColumnWidth(min: 196, ideal: 218, max: 280)
        } detail: {
            // 四个页面共享同一个 GeometryReader + ScrollView。切换时只替换内部内容，
            // 避免两套顶层 NSScrollView 同时参与窗口和标题栏布局。
            PageContainer(scrollResetID: app.page) {
                ZStack(alignment: .topLeading) {
                    currentPage
                        .id(app.page)
                        .opacity(pageOpacity)
                        .offset(y: pageOffset)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            // macOS 13 的 NavigationSplitView 会偶尔把默认侧栏切换按钮留为首个键盘焦点，
            // 从而显示一圈持久蓝框。清除首次残留焦点，不影响该按钮日后的正常使用。
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onDisappear {
            navigationTask?.cancel()
            navigationTask = nil
            pendingPage = nil
        }
    }

    @ViewBuilder private var currentPage: some View {
        switch app.page {
        case .run: RunView()
        case .data: DataView()
        case .stats: StatsView()
        case .settings: SettingsView()
        }
    }

    private func selectPage(_ page: Page) {
        let currentTarget = pendingPage ?? app.page
        guard page != currentTarget else { return }

        navigationTask?.cancel()
        pendingPage = page

        // 点击正在淡出的当前页等同于取消切换，平滑恢复当前内容。
        guard page != app.page else {
            pendingPage = nil
            withAnimation(AppMotion.navigationEnter) {
                pageOpacity = 1
                pageOffset = 0
            }
            return
        }

        guard !reduceMotion else {
            app.page = page
            pendingPage = nil
            pageOpacity = 1
            pageOffset = 0
            return
        }

        let direction: CGFloat = page.navigationIndex > app.page.navigationIndex ? 1 : -1
        navigationTask = Task { @MainActor in
            // 先让旧页完整淡出；此阶段仍只有旧页这一棵复杂视图树。
            withAnimation(AppMotion.navigationExit) {
                pageOpacity = 0
                pageOffset = -3 * direction
            }

            do {
                try await Task.sleep(nanoseconds: AppMotion.navigationExitNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            // 在完全透明的一帧里无动画替换页面，并把新页放到对应方向的起点。
            var replacement = Transaction()
            replacement.disablesAnimations = true
            withTransaction(replacement) {
                app.page = page
                pendingPage = nil
                pageOffset = 6 * direction
            }

            await Task.yield()
            guard !Task.isCancelled else { return }

            withAnimation(AppMotion.navigationEnter) {
                pageOpacity = 1
                pageOffset = 0
            }
        }
    }
}

// 自定义侧边栏将路由状态映射为安静的 teal 选中态，避免 macOS 默认蓝色
// 与产品强调色冲突。每个项目保留原有的路由、标签与操作。
struct SidebarContent: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accentPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onSelect: (Page) -> Void
    @State private var hoveredPage: Page?
    @Namespace private var selectionAnimation

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
            // 侧栏只动画选中背景，不把路由动画事务扩散到分栏布局。
            .animation(reduceMotion ? nil : AppMotion.mainNavigationSelection, value: app.page)

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
            onSelect(page)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18)
                Text(page.rawValue)
                    .font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.fg : Theme.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if selected {
                    if reduceMotion {
                        selectionPill
                    } else {
                        selectionPill
                            .matchedGeometryEffect(id: "sidebar-selection", in: selectionAnimation)
                    }
                } else if hovered {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.panel2.opacity(0.65))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering in
            hoveredPage = isHovering ? page : nil
        }
    }

    private var selectionPill: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(palette.accentSoft)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(palette.accentLine.opacity(0.7), lineWidth: 1)
            )
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
    var scrollResetID: AnyHashable? = nil
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            // 两侧固定保留 36pt；窗口再窄时也避免出现负宽度。
            let columnWidth = max(1, min(maxWidth, proxy.size.width - 72))
            // 不用 `frame(maxWidth: .infinity)` 再居中：macOS 在纵向滚动条出现时会缩窄
            // ScrollView 的内部可视宽度，导致整列内容向左跳几 pt。这里依据外层 GeometryReader
            // 固定左右留白，因此加载、折叠或刷新改变页面高度时，卡片的 x 坐标保持不变。
            let sideInset = max(36, (proxy.size.width - columnWidth) / 2)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id(PageContainerAnchor.top)

                        content
                            .frame(width: columnWidth, alignment: .topLeading)
                            .padding(.leading, sideInset)
                            .padding(.trailing, sideInset)
                            .padding(.top, 36)
                            .padding(.bottom, 56)
                    }
                }
                .background(Theme.canvas)
                .onChange(of: scrollResetID) { _ in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scrollProxy.scrollTo(PageContainerAnchor.top, anchor: .top)
                    }
                }
            }
        }
    }
}

private enum PageContainerAnchor {
    static let top = "main-page-top"
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
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }
}

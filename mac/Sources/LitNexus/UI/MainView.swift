import SwiftUI

struct MainView: View {
    @EnvironmentObject var app: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarContent()
                .navigationSplitViewColumnWidth(min: 168, ideal: 196, max: 280)
        } detail: {
            Group {
                switch app.page {
                case .run: RunView()
                case .data: DataView()
                case .stats: StatsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.bg)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// 原生侧边栏：系统列表选择（自带选中高亮、随明暗自适应、分隔条可拖）。
struct SidebarContent: View {
    @EnvironmentObject var app: AppState

    private var selection: Binding<Page?> {
        Binding(get: { app.page }, set: { if let v = $0 { app.page = v } })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(Page.allCases, id: \.self) { p in
                Label(p.rawValue, systemImage: icon(p))
                    .font(.system(size: 14))
                    .tag(p)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("LitNexus")
        .safeAreaInset(edge: .bottom) { footer }
    }

    @ViewBuilder private var footer: some View {
        if let ws = app.workspace {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("当前项目")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(ws.root.lastPathComponent)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 8) {
                    Button { revealInFinder(ws.root) } label: {
                        Label("目录", systemImage: "folder")
                    }
                    .help("在 Finder 中打开项目目录")
                    Button { app.switchProject() } label: {
                        Label("切换", systemImage: "arrow.left.arrow.right")
                    }
                    .help("切换到其他项目")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 4)
        }
    }

    private func icon(_ p: Page) -> String {
        switch p {
        case .run: return "play.circle"
        case .data: return "cylinder.split.1x2"
        case .stats: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}

// 各页通用容器：可滚动 + 居中定宽栏（窗口宽时封顶 760，窄时跟随收窄）+ 统一内边距。
struct PageContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                content.frame(maxWidth: 760, alignment: .topLeading)
                Spacer(minLength: 0)
            }
            .padding(28)
        }
    }
}

// 各页通用的标题区。
struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 25, weight: .bold))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.muted)
        }
    }
}

import SwiftUI

struct MainView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Group {
                switch app.page {
                case .run: RunView()
                case .data: DataView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.bg)
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "testtube.2").foregroundStyle(Theme.accent)
                Text("LitNexus").font(.system(size: 16, weight: .bold))
            }
            .padding(.bottom, 18)

            ForEach(Page.allCases, id: \.self) { navItem($0) }

            Spacer()
            Divider().overlay(Theme.line)
            if let ws = app.workspace {
                Text("当前项目").font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 8)
                Text(ws.root.lastPathComponent)
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                HStack(spacing: 12) {
                    Button { revealInFinder(ws.root) } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain).help("打开项目目录")
                    Button { app.switchProject() } label: { Image(systemName: "arrow.left.arrow.right") }
                        .buttonStyle(.plain).help("切换项目")
                }
                .foregroundStyle(Theme.muted).padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func navItem(_ p: Page) -> some View {
        let active = app.page == p
        return Button { app.page = p } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(p)).frame(width: 18)
                Text(p.rawValue)
                Spacer()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? Theme.fg : Theme.muted)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(active ? Theme.panel2 : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())  // 整行可点，而非仅文字/图标
        }
        .buttonStyle(.plain)
    }

    private func icon(_ p: Page) -> String {
        switch p {
        case .run: return "play.circle"
        case .data: return "cylinder.split.1x2"
        case .settings: return "gearshape"
        }
    }
}

// 各页通用的标题区。
struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
    }
}

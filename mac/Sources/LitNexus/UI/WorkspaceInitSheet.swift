import SwiftUI
import AppKit

// 打开/新建工作区时，所选文件夹非空且不是工作区 → 让用户决定如何初始化。
// 默认在其中新建子文件夹（推荐）；「直接使用此文件夹」需再过一次强警告，
// 且危险路径（家目录、系统目录、云盘根等）禁用就地初始化。
struct WorkspaceInitSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accentPalette) private var palette
    let pending: PendingWorkspaceInit
    @State private var name = "LitNexusDB"
    @State private var decided = false

    private enum Choice { case subfolder, direct }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("所选文件夹非空，且不是 LitNexus 工作区")
                .font(.system(size: 17, weight: .bold))
            Text("为避免影响其中的现有内容，将在该文件夹下新建子文件夹作为工作区。")
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("子文件夹名").font(.system(size: 13)).foregroundStyle(Theme.muted)
                TextField("LitNexusDB", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if pending.isDangerous {
                Text("此位置受保护，只能在其中新建子文件夹。")
                    .font(.system(size: 12)).foregroundStyle(Theme.red)
            }

            HStack {
                Button("直接使用此文件夹…") { useDirect() }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(pending.isDangerous)
                Spacer()
                Button("取消") { finish(nil) }
                    .buttonStyle(.bordered).controlSize(.large)
                Button("新建子文件夹") { finish(.subfolder) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .tint(palette.accent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 440).background(Theme.panel)
        .onDisappear { if !decided { app.cancelInit() } }  // 兜底：被动关闭 = 取消
    }

    private func useDirect() {
        guard !pending.isDangerous else { return }
        if warnDirectUse() { finish(.direct) }
    }

    // 就地初始化的二次强警告（系统原生 NSAlert）。
    private func warnDirectUse() -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "直接在此文件夹初始化工作区？"
        a.informativeText = "不建议这样做。除非你清楚自己在做什么，否则请返回并选择「新建子文件夹」。就地初始化会向该文件夹添加 litnexus.toml、downloads/、exports/ 等文件。"
        a.addButton(withTitle: "返回")
        a.addButton(withTitle: "我了解风险，继续")
        return a.runModal() == .alertSecondButtonReturn
    }

    private func finish(_ choice: Choice?) {
        decided = true
        guard let choice else { app.cancelInit(); return }
        switch choice {
        case .subfolder: app.confirmInitNewSubfolder(name)
        case .direct: app.confirmInitUseDirect()
        }
    }
}
import SwiftUI
import AppKit

// 入口：带 selftest/epmctest 参数时跑引擎自检（无界面环境），否则启动 GUI。
@main
struct EntryPoint {
    static func main() {
        if CommandLine.arguments.contains("selftest") {
            SelfTest.run()
            return
        }
        if CommandLine.arguments.contains("epmctest") {
            SelfTestLive.run()
            return
        }
        if CommandLine.arguments.contains("aitest") {
            SelfTestAI.run()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "csvtest"),
           CommandLine.arguments.count > i + 1 {
            CSVTest.run(path: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "migrate"),
           CommandLine.arguments.count > i + 2 {
            MigrateTool.run(oldDB: CommandLine.arguments[i + 1], outDB: CommandLine.arguments[i + 2])
            return
        }
        LitNexusApp.main()
    }
}

struct LitNexusApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("LitNexus") {
            RootView()
                .environmentObject(app)
                // 固定基线不随当前路由或过渡内容改变；窄于此尺寸时主操作栏会失去可读布局。
                .frame(minWidth: 960, minHeight: 680)
                .background(WindowChromeConfigurator().frame(width: 0, height: 0))
                .onAppear { applyAppearance(app.appearance) }
                .onChange(of: app.appearance) { applyAppearance($0) }
        }
        .defaultSize(width: 1160, height: 760)
        .windowStyle(.titleBar)
        // 页面切换时只重新布局内容，不让旧、新页面的理想尺寸参与窗口 chrome 协商。
        .windowResizability(.contentMinSize)
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        NSApp.appearance = appearance.appKitAppearance
    }
}

/// SwiftUI 的 NavigationSplitView 默认让 AppKit 自动判断标题栏分隔线。
/// 显式固定窗口级样式，避免内容滚动状态变化时系统重新计算分隔线。
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeProbe {
        WindowChromeProbe()
    }

    func updateNSView(_ nsView: WindowChromeProbe, context: Context) {
        nsView.applyTitlebarStyle()
    }
}

private final class WindowChromeProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTitlebarStyle()
    }

    func applyTitlebarStyle() {
        guard let window, window.titlebarSeparatorStyle != .line else { return }
        // 窗口级偏好会覆盖 NSSplitViewItem 的 automatic 偏好，并在页面切换期间保持稳定。
        window.titlebarSeparatorStyle = .line
    }
}

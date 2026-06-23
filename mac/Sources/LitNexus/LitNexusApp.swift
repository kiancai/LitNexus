import SwiftUI

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
                .frame(minWidth: 560, minHeight: 520)
                .preferredColorScheme(app.appearance.colorScheme)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
}

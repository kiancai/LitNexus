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
        LitNexusApp.main()
    }
}

struct LitNexusApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("LitNexus") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 920, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
}

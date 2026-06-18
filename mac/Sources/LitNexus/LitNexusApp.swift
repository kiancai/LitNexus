import SwiftUI

// LitNexus 原生 macOS 应用入口（SwiftUI）。
// 这是纯原生重写的骨架：界面用系统 AppKit/SwiftUI 渲染，逻辑后续逐步从
// Python 参考实现（仓库 src/litnexus）1:1 移植过来。

@main
struct LitNexusApp: App {
    var body: some Scene {
        WindowGroup("LitNexus") {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "testtube.2")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("LitNexus")
                .font(.system(size: 30, weight: .bold))
            Text("原生重写骨架 · 已可编译运行")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 720, minHeight: 480)
        .padding(40)
    }
}

// 石墨黑 + 靓蓝配色（与之前选定方案一致），后续在此扩展为完整主题。
enum Theme {
    static let accent = Color(red: 0x63 / 255, green: 0x66 / 255, blue: 0xF1 / 255)
}

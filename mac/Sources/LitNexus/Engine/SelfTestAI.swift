import Foundation

// 临时：用环境变量里的接口直接跑 AIClient.chat，定位测试连接失败原因。
// 运行：LNX_BASE=.. LNX_KEY=.. LNX_MODEL=.. swift run LitNexus aitest

enum SelfTestAI {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        let typed = AIConfig(apiKey: env["LNX_KEY"] ?? "", baseURL: env["LNX_BASE"] ?? "",
                             model: env["LNX_MODEL"] ?? "", extraParams: env["LNX_EXTRA"] ?? "")
        // 走与界面相同的 resolvedAI 路径（验证环境变量不再顶替用户输入）
        let ai = AppConfig(ai: typed).resolvedAI
        print("base=\(ai.baseURL) model=\(ai.model) 用的key前缀=\(ai.apiKey.prefix(6)) extra=\(ai.extraParams)")
        do {
            let content = try AIClient.chat(ai: ai, system: "你是助手", user: "只回复两个字：你好", temperature: 0.0)
            print("✓ chat 成功，content=[\(content)] (len=\(content.count))")
        } catch {
            print("✗ chat 失败：\(error)  ——  \((error as? HTTPError)?.errorDescription ?? "")")
        }
        exit(0)
    }
}

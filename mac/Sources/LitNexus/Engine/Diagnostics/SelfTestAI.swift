import Foundation

// Opt-in live AI diagnostic entry point.

// 临时：用环境变量里的接口直接跑 AIClient.chat，定位测试连接失败原因。
// 运行：LNX_BASE=.. LNX_KEY=.. LNX_MODEL=.. swift run LitNexus aitest

enum SelfTestAI {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        let typed = AIConfig(apiKey: env["LNX_KEY"] ?? "", baseURL: env["LNX_BASE"] ?? "",
                             model: env["LNX_MODEL"] ?? "", extraParams: env["LNX_EXTRA"] ?? "")
        let ai = typed
        print("base=\(ai.baseURL) model=\(ai.model) 用的key前缀=\(ai.apiKey.prefix(6)) extra=\(ai.extraParams)")
        do {
            let content = try AIClient.chat(ai: ai, system: "你是助手", user: "只回复两个字：你好", temperature: 0.0)
            print("✓ ping 成功，content=[\(content)] (len=\(content.count))")
        } catch {
            print("✗ ping 失败：\(error)  ——  \((error as? HTTPError)?.errorDescription ?? "")")
        }

        // 批量翻译实测：打印原始返回 + 解析结果，定位「翻译全失败」
        print("\n--- 批量翻译测试 ---")
        let payload = [["id": 1, "text": "A deep learning framework for protein structure prediction"],
                       ["id": 2, "text": "Single-cell RNA sequencing reveals immune dynamics"]]
        let userMsg = String(data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(), encoding: .utf8) ?? "[]"
        do {
            let raw = try AIClient.chat(ai: ai, system: AIClient.translateSystemPrompt("title"), user: userMsg, temperature: 0.1)
            print("原始返回：\(raw)")
            let parsed = AIClient.parseBatchResponse(raw, valueKey: "text_zh")
            print("解析结果：\(parsed)")
        } catch {
            print("✗ 批量翻译 chat 失败：\(error)")
        }
        exit(0)
    }
}

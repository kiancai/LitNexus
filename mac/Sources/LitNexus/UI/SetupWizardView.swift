import SwiftUI

struct SetupWizardView: View {
    @EnvironmentObject var app: AppState
    @State private var step = 0
    @State private var journals = ""
    @State private var keywords = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("首次设置").font(.system(size: 24, weight: .bold))
            }
            if let ws = app.workspace {
                Text("项目：\(ws.root.path)").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }

            if step == 0 {
                Card {
                    SectionTitle("第一步 · 检索列表")
                    Text("用于确定抓取范围，已预填示例，可按需修改。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    fieldLabel("期刊（每行一个）")
                    editor($journals, height: 110)
                    fieldLabel("关键词检索式（每行一个）")
                    editor($keywords, height: 90)
                    HStack {
                        Spacer()
                        Button("下一步") { step = 1 }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            } else {
                Card {
                    SectionTitle("第二步 · AI 接口")
                    Text("翻译与分类需要一个 OpenAI 兼容接口（无默认值，请填写你的服务商信息）。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    fieldLabel("Base URL")
                    input($baseURL)
                    Text("填到 /v1 即可，例：https://api.xiaomimimo.com/v1（填完整的 /chat/completions 也认）")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    fieldLabel("模型名")
                    input($model)
                    fieldLabel("API Key")
                    SecureField("", text: $apiKey).textFieldStyle(.plain)
                        .padding(8).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button(testing ? "测试中…" : "测试连接") { testConnection() }
                            .buttonStyle(OutlineButtonStyle()).disabled(testing)
                        Spacer()
                        Button("上一步") { step = 0 }.buttonStyle(OutlineButtonStyle())
                        Button("完成设置") { finish() }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            }

            Button("跳过") { app.route = .main }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
        }
        .padding(40)
        .frame(maxWidth: 680)
        .onAppear {
            journals = app.readJournals()
            keywords = app.readKeywords()
            baseURL = app.config.ai.baseURL
            model = app.config.ai.model
            apiKey = app.config.ai.apiKey
        }
    }

    private func testConnection() {
        testing = true
        app.testAIConnection(AIConfig(apiKey: apiKey, baseURL: baseURL, model: model)) { _, msg in
            testing = false; app.toast = msg
        }
    }

    private func finish() {
        var cfg = app.config
        cfg.ai = AIConfig(apiKey: apiKey.trimmingCharacters(in: .whitespaces),
                          baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                          model: model.trimmingCharacters(in: .whitespaces))
        app.saveConfig(cfg, journals: journals, keywords: keywords)
        app.route = .main
    }

    @ViewBuilder private func fieldLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
    }
    @ViewBuilder private func input(_ b: Binding<String>) -> some View {
        TextField("", text: b).textFieldStyle(.plain).lineLimit(1)
            .padding(8).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func editor(_ b: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: b)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6).frame(height: height)
            .background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

import SwiftUI

struct RunView: View {
    @EnvironmentObject var app: AppState
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "运行", subtitle: "依次执行下载、合并、翻译、分类四个步骤")

                Card {
                    SectionTitle("检索范围")
                    HStack(spacing: 16) {
                        Picker("下载模式", selection: $app.downloadMode) {
                            Text("全部").tag("all")
                            Text("仅期刊").tag("journals")
                            Text("仅关键词").tag("keywords")
                        }
                        .frame(width: 220)
                        HStack(spacing: 6) {
                            Text("最近天数").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            TextField("", value: $app.downloadDays, format: .number)
                                .textFieldStyle(.plain).lineLimit(1).frame(width: 60)
                                .padding(6).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Spacer()
                        if app.isRunning { ProgressView().controlSize(.small) }
                        Button("运行全部") { app.runAll() }
                            .buttonStyle(PrimaryButtonStyle()).disabled(app.isRunning)
                    }
                }

                VStack(spacing: 10) {
                    ForEach(app.steps) { step in
                        StepRow(step: step) { app.runOne(step.id) }
                    }
                }

                DisclosureGroup(isExpanded: $showLog) {
                    logPane
                } label: {
                    Text("详细日志").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                }
                .tint(Theme.muted)
            }
            .padding(28)
        }
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(app.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .frame(height: 200)
            .background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: app.logLines.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .padding(.top, 8)
    }
}

struct StepRow: View {
    let step: PipelineStep
    let onRun: () -> Void
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(step.name).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("运行") { onRun() }
                        .buttonStyle(OutlineButtonStyle()).controlSize(.small).disabled(app.isRunning)
                }
                Text(step.subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted)
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(step.status == .failed ? Theme.red : Theme.green)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius)
            .stroke(step.status == .failed ? Theme.red.opacity(0.5) : Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    @ViewBuilder private var statusIcon: some View {
        switch step.status {
        case .idle: Image(systemName: "circle").foregroundStyle(Theme.muted)
        case .running: ProgressView().controlSize(.small)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.red)
        }
    }
}

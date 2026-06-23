import SwiftUI

struct RunView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "运行", subtitle: "默认一键运行全部：下载 → 合并 → 翻译 → 分类")

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
                    ForEach(app.steps) { step in StepRow(step: step) }
                }

                Card {
                    Expander("高级操作：单独运行某一步") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(verbatim: "通常不需要。仅在你只想补跑某一步时使用，例如新增了一个问题后只想补跑「智能分类」。单独运行会先二次确认。")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            HStack(spacing: 8) {
                                ForEach(app.steps) { step in
                                    Button(step.name) { app.runOne(step.id) }
                                        .buttonStyle(OutlineButtonStyle()).controlSize(.small)
                                        .disabled(app.isRunning)
                                }
                            }
                            if app.hasAutoApproved {
                                Divider().overlay(Theme.line).padding(.vertical, 2)
                                HStack {
                                    Text(verbatim: "已对部分 AI 步骤设为「默认同意」，运行前不再询问。")
                                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                                    Spacer()
                                    Button("恢复运行前询问") {
                                        app.setAutoApproved("translate", false)
                                        app.setAutoApproved("classify", false)
                                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }

                Card { Expander("详细日志") { logPane } }
            }
            .padding(28)
        }
        .sheet(item: $app.pendingConfirm) { c in ConfirmSheet(confirm: c) }
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
            .frame(height: 220)
            .background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: app.logLines.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct StepRow: View {
    let step: PipelineStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.name).font(.system(size: 14, weight: .semibold))
                Text(step.subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted)

                if step.status == .running {
                    if !step.subs.isEmpty {
                        ForEach(step.subs) { sub in subRow(sub) }
                    } else if let p = step.progress {
                        ProgressView(value: p).tint(Theme.accent).padding(.top, 4)
                        HStack(spacing: 6) {
                            Text("\(step.current) / \(step.total)（\(Int(p * 100))%）")
                            if !step.eta.isEmpty { Text("· 预计剩余 \(step.eta)") }
                        }
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    } else {
                        Text("进行中…").font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 2)
                    }
                }

                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(detailColor)
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

    private var detailColor: Color {
        switch step.status {
        case .failed: return Theme.red
        case .idle: return Theme.muted
        default: return Theme.green
        }
    }

    @ViewBuilder private func subRow(_ sub: SubProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(sub.label).font(.system(size: 11, weight: .medium)).frame(width: 52, alignment: .leading)
                ProgressView(value: sub.progress ?? 0).tint(Theme.accent)
                Text("\(sub.current) / \(sub.total)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .frame(width: 70, alignment: .trailing)
            }
            if !sub.eta.isEmpty {
                Text(verbatim: "预计剩余 \(sub.eta)")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.leading, 58)
            }
            if !sub.item.isEmpty {
                Text(verbatim: "当前：\(sub.item)")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 58)
            }
        }
        .padding(.top, 4)
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

// AI / 单独运行步骤前的二次确认弹窗，可勾「以后默认同意」。
struct ConfirmSheet: View {
    let confirm: PendingConfirm
    @State private var remember = false
    @State private var decided = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(confirm.title).font(.system(size: 16, weight: .bold))
            Text(confirm.message)
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("以后默认同意，不再询问（可在弹出前取消）", isOn: $remember)
                .toggleStyle(.checkbox).font(.system(size: 12))
            HStack {
                Spacer()
                Button("取消") { finish(false) }.buttonStyle(OutlineButtonStyle())
                Button("确认运行") { finish(true) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24).frame(width: 440).background(Theme.panel)
        .onDisappear { if !decided { confirm.onResult(false, false) } }  // 兜底：被动关闭=取消
    }

    private func finish(_ approved: Bool) {
        decided = true
        confirm.onResult(approved, remember)
    }
}

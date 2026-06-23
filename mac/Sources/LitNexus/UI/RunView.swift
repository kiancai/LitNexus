import SwiftUI
import AppKit

struct RunView: View {
    @EnvironmentObject var app: AppState

    private var showConsole: Bool { app.isRunning || !app.logLines.isEmpty }

    var body: some View {
        PageContainer {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "运行", subtitle: "依次执行：下载 · 合并 · 翻译 · 分类")

                controlBar

                GroupBox {
                    PipelineTimeline(steps: app.steps).padding(6)
                }

                if showConsole { logConsole }
            }
        }
        .sheet(item: $app.pendingConfirm) { c in ConfirmSheet(confirm: c) }
    }

    // 轻量工具条：范围 + 天数 + 运行；高级操作收进右侧菜单。不再是卡片。
    private var controlBar: some View {
        HStack(spacing: 14) {
            Picker("范围", selection: $app.downloadMode) {
                Text("全部").tag("all")
                Text("仅期刊").tag("journals")
                Text("仅关键词").tag("keywords")
            }
            .fixedSize()

            HStack(spacing: 6) {
                Text("最近").foregroundStyle(Theme.muted)
                TextField("", value: $app.downloadDays, format: .number)
                    .frame(width: 48).textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                Text("天").foregroundStyle(Theme.muted)
            }

            Spacer()

            if app.isRunning {
                ProgressView().controlSize(.small)
                Button { app.cancelRun() } label: {
                    Label(app.isCancelling ? "正在中止…" : "中止", systemImage: "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.red)
                .disabled(app.isCancelling)
            } else {
                Button { app.runAll() } label: {
                    Label("运行", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.accent)
            }

            Menu {
                Section("单独运行某一步") {
                    ForEach(app.steps) { step in
                        Button(step.name) { app.runOne(step.id) }.disabled(app.isRunning)
                    }
                }
                if app.hasAutoApproved {
                    Divider()
                    Button("恢复运行前询问") {
                        app.setAutoApproved("translate", false)
                        app.setAutoApproved("classify", false)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("高级操作")
        }
    }

    // 控制台：仅在运行中或已有日志时出现；自带标题栏 + 运行指示灯 + 复制。
    private var logConsole: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if app.isRunning {
                    Circle().fill(Theme.green).frame(width: 7, height: 7)
                }
                Text("运行日志").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                Spacer()
                if !app.logLines.isEmpty {
                    Button { copyLog() } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.muted).help("复制全部日志")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(Theme.line)
            consoleBody
        }
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(height: 300)   // 固定高度的独立小块；日志再长也只在内部滚动，不撑长页面
    }

    @ViewBuilder private var consoleBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if app.logLines.isEmpty {
                    Text("正在启动…").font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(app.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(lineColor(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: app.logLines.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func lineColor(_ line: String) -> Color {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("⚠") || t.hasPrefix("✗") { return Theme.amber }
        if t.hasPrefix("---") { return Theme.cyan }                 // 分组标题（抓取期刊/检索式）
        if line.first == " " { return Theme.muted.opacity(0.85) }   // 缩进的明细行
        if t.isEmpty { return Theme.muted }
        return Theme.fg.opacity(0.9)                                // 顶层信息行
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(app.logLines.joined(separator: "\n"), forType: .string)
    }
}

// 竖向时间线：四步串在一条竖线上，进行中的那步就地展开进度。
struct PipelineTimeline: View {
    let steps: [PipelineStep]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                TimelineRow(step: step, isLast: idx == steps.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TimelineRow: View {
    let step: PipelineStep
    let isLast: Bool

    private var bottomPad: CGFloat { isLast ? 2 : (step.status == .running ? 16 : 9) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            node.frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(step.status == .idle ? Theme.muted : Theme.fg)
                Text(step.subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted)

                if step.status == .running {
                    if !step.subs.isEmpty {
                        ForEach(step.subs) { sub in subRow(sub) }
                    } else if let p = step.progress {
                        ProgressView(value: p).tint(Theme.accent).padding(.top, 4)
                        HStack(spacing: 6) {
                            Text("\(step.current) / \(step.total)（\(Int(p * 100))%）")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Spacer()
                            timers(startedAt: step.startedAt, deadline: step.etaDeadline)
                        }
                    } else {
                        Text("进行中…").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 2)
                    }
                }

                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(detailColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }

                if !step.warning.isEmpty {
                    Label { Text(step.warning) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.system(size: 12)).foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(.bottom, bottomPad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 连接线用 overlay 画在节点正下方，高度自然等于本行内容高度——不会把行撑大。
        .overlay(alignment: .topLeading) {
            if !isLast {
                Rectangle().fill(Theme.line).frame(width: 2)
                    .padding(.top, 24).padding(.leading, 10)
            }
        }
    }

    private var detailColor: Color {
        switch step.status {
        case .failed: return Theme.red
        case .idle: return Theme.muted
        default: return Theme.green
        }
    }

    // 双计时器：已用（正计时，完成即冻结）+ 剩余（倒计时，下载步骤不显示）。
    @ViewBuilder private func timers(startedAt: Date?, endedAt: Date? = nil, deadline: Date?) -> some View {
        if let s = startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let elapsedNow = endedAt ?? ctx.date
                HStack(spacing: 10) {
                    Text("已用 \(AppState.clock(elapsedNow.timeIntervalSince(s)))")
                    if endedAt == nil, let d = deadline {
                        Text("剩余 \(AppState.clock(max(0, d.timeIntervalSince(ctx.date))))")
                    }
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder private func subRow(_ sub: SubProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(sub.label).font(.system(size: 12, weight: .medium)).frame(width: 52, alignment: .leading)
                ProgressView(value: sub.progress ?? 0).tint(Theme.accent)
                Text("\(sub.current) / \(sub.total)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .frame(width: 70, alignment: .trailing)
            }
            timers(startedAt: sub.startedAt, endedAt: sub.endedAt, deadline: sub.etaDeadline)
                .padding(.leading, 58)
            if !sub.item.isEmpty {
                Text(verbatim: "当前：\(sub.item)")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 58)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var node: some View {
        switch step.status {
        case .idle: Image(systemName: "circle").font(.system(size: 16)).foregroundStyle(Theme.muted)
        case .running: ProgressView().controlSize(.small)
        case .success: Image(systemName: "checkmark.circle.fill").font(.system(size: 19)).foregroundStyle(Theme.green)
        case .failed: Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 19)).foregroundStyle(Theme.red)
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
            Text(confirm.title).font(.system(size: 17, weight: .bold))
            Text(confirm.message)
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("以后默认同意，不再询问（可在弹出前取消）", isOn: $remember)
                .toggleStyle(.checkbox).font(.system(size: 13))
            HStack {
                Spacer()
                Button("取消") { finish(false) }.buttonStyle(.bordered).controlSize(.large)
                Button("确认运行") { finish(true) }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.accent)
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

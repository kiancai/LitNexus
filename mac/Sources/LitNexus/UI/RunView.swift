import SwiftUI
import AppKit

struct RunView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accentPalette) private var palette
    @State private var recordsExpanded = false
    @State private var showsTechnicalRecords = false

    private var showRecords: Bool { app.isRunning || !app.runRecords.isEmpty }

    var body: some View {
        PageContainer {
            VStack(alignment: .leading, spacing: 16) {
                runHeader
                runControlDeck
                workflow

                if showRecords { runRecordsPanel }
            }
        }
        .sheet(item: $app.pendingConfirm) { c in ConfirmSheet(confirm: c) }
        .onAppear { updateRecordExpansionForCurrentState() }
        .onChange(of: app.isRunning) { _ in updateRecordExpansionForCurrentState() }
        .onChange(of: app.runRecords.count) { _ in
            if app.runRecords.last?.event.level != .info { recordsExpanded = true }
        }
    }

    // 页面说明收进标题旁的帮助浮层；状态放在卡片外的右上角，避免与主操作竞争。
    private var runHeader: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PageHeader(title: "运行", guide: PageGuides.run, symbol: Page.run.symbol)
            Spacer(minLength: 16)
            runStateBadge
                .padding(.bottom, 2)
        }
    }

    // 一张明确的「本次运行」操作面板：更多操作属于面板标题，主操作只保留运行本身。
    private var runControlDeck: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .firstTextBaseline) {
                Text("本次运行")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Spacer()
                advancedMenu
            }

            HStack(alignment: .bottom, spacing: 20) {
                HStack(spacing: 16) {
                    scopeControl

                    Rectangle()
                        .fill(Theme.line)
                        .frame(width: 1, height: 32)

                    dayWindowControl
                }

                Spacer(minLength: 18)

                runAction
            }
        }
        .padding(20)
        .surface(fill: Theme.panel, cornerRadius: 16, elevated: true)
    }

    private var runStateBadge: some View {
        RunStateBadge(
            label: app.isCancelling ? "正在中止" : (app.isRunning ? "正在运行" : "准备就绪"),
            color: app.isCancelling ? Theme.amber : (app.isRunning ? palette.accent : Theme.muted)
        )
    }

    private var scopeControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("获取范围")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)

            Picker("获取范围", selection: $app.downloadMode) {
                Text("全部").tag("all")
                Text("仅期刊").tag("journals")
                Text("仅关键词").tag("keywords")
            }
            .labelsHidden()
            .frame(width: 126)
        }
    }

    private var dayWindowControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("时间窗口")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)

            HStack(spacing: 6) {
                Text("最近").foregroundStyle(Theme.muted)
                TextField("", value: $app.downloadDays, format: .number)
                    .frame(width: 48)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("最近天数")
                Text("天").foregroundStyle(Theme.muted)
            }
            .font(.system(size: 13))
        }
    }

    @ViewBuilder private var runAction: some View {
        if app.isRunning {
            Button { app.cancelRun() } label: {
                Label(app.isCancelling ? "正在中止…" : "中止", systemImage: "stop.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.red)
            .disabled(app.isCancelling)
        } else {
            Button { app.runAll() } label: {
                Label("开始运行", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(palette.accent)
        }
    }

    private var advancedMenu: some View {
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
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Theme.panel2)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("高级操作")
    }

    private var workflow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text("执行路径")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.fg)

                Spacer()

                Label("\(app.steps.count) 个步骤", systemImage: "circle.grid.2x2")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.panel2)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.top, 19)
            .padding(.bottom, 16)

            Divider().overlay(Theme.line)

            PipelineTimeline(steps: app.steps)
                .padding(14)
                .padding(.bottom, 10)
        }
        .surface(fill: Theme.panel, cornerRadius: 16)
    }

    // 运行记录：默认只显示结构化摘要。原始诊断在用户主动切到「技术详情」时才显示，
    // 避免引擎中的换行、缩进和中英文混排直接成为正常工作流的一部分。
    private var runRecordsPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if app.isRunning {
                    Circle().fill(Theme.green).frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("运行记录")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    Text(recordHeaderSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()

                if !app.runRecords.isEmpty {
                    Button {
                        showsTechnicalRecords.toggle()
                    } label: {
                        Text(showsTechnicalRecords ? "摘要" : "技术详情")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Theme.panel2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(showsTechnicalRecords ? "只显示摘要记录" : "显示原始技术诊断")

                    Button { copyDiagnostics() } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.muted)
                    .help("复制诊断")
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { recordsExpanded.toggle() }
                } label: {
                    Image(systemName: recordsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Theme.panel2)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(recordsExpanded ? "收起运行记录" : "展开运行记录")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            if recordsExpanded {
                Divider().overlay(Theme.line)
                runRecordList
            }
        }
        .surface(fill: Theme.panel, cornerRadius: 14)
    }

    @ViewBuilder private var runRecordList: some View {
        let records = visibleRecords
        ScrollView {
            if records.isEmpty {
                Text(app.isRunning ? "正在建立本次运行记录…" : "暂无可显示的记录。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(records) { record in
                        runRecordRow(record)
                        if record.id != records.last?.id {
                            Divider().overlay(Theme.line.opacity(0.78)).padding(.leading, 50)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: showsTechnicalRecords ? 300 : 230)
    }

    @ViewBuilder private func runRecordRow(_ record: RunRecord) -> some View {
        let color = recordColor(record)
        HStack(alignment: .top, spacing: 10) {
            Text(record.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .frame(width: 50, alignment: .leading)

            Image(systemName: recordSymbol(record))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(color.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text("\(stepLabel(record.stepID)) · \(recordSummary(record))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = recordDetail(record) {
                    Text(detail)
                        .font(.system(size: showsTechnicalRecords ? 11 : 12,
                                     design: showsTechnicalRecords ? .monospaced : .default))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleRecords: [RunRecord] {
        if showsTechnicalRecords { return app.runRecords }
        return app.runRecords.filter { record in
            record.event.category == .lifecycle || record.event.level != .info
        }
    }

    private var hasRecordProblem: Bool {
        app.runRecords.contains { $0.event.level == .warning || $0.event.level == .error }
    }

    private var recordHeaderSummary: String {
        if app.isRunning { return "正在记录本次运行" }
        let issueCount = app.runRecords.filter { $0.event.level == .warning || $0.event.level == .error }.count
        if issueCount > 0 { return "\(issueCount) 条需要注意" }
        let completed = app.runRecords.filter { $0.event.code == "pipeline.step.succeeded" }.count
        return completed > 0 ? "\(completed) 个步骤已完成" : "尚未开始"
    }

    private func updateRecordExpansionForCurrentState() {
        if app.isRunning { recordsExpanded = true }
        else if !hasRecordProblem { recordsExpanded = false }
    }

    private func stepLabel(_ stepID: String?) -> String {
        guard let stepID else { return "运行" }
        return app.steps.first(where: { $0.id == stepID })?.name ?? stepID
    }

    private func recordSummary(_ record: RunRecord) -> String {
        switch record.event.code {
        case "pipeline.step.started":
            return "开始"
        case "pipeline.step.succeeded":
            if let milliseconds = record.event.values["duration_milliseconds"].flatMap(Double.init) {
                return "完成 · 耗时 \(AppState.formatDuration(milliseconds / 1_000))"
            }
            return "完成"
        case "pipeline.step.failed":
            return "失败"
        case "pipeline.step.cancelled":
            return "已中止"
        case "pipeline.cancellation.requested":
            return "已请求中止"
        case "engine.legacy.warning":
            return "警告"
        case "engine.legacy.log":
            return "技术记录"
        case "progress.task.started":
            return "任务开始"
        case "progress.task.completed":
            return "任务完成"
        default:
            return record.event.code
        }
    }

    private func recordDetail(_ record: RunRecord) -> String? {
        let technical = record.event.technicalText?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch record.event.code {
        case "pipeline.step.failed", "engine.legacy.warning":
            return technical
        default:
            return showsTechnicalRecords ? technical : nil
        }
    }

    private func recordColor(_ record: RunRecord) -> Color {
        switch record.event.code {
        case "pipeline.step.succeeded": return Theme.green
        case "pipeline.step.started": return palette.accent
        case "pipeline.cancellation.requested", "engine.legacy.warning": return Theme.amber
        case "pipeline.step.failed": return Theme.red
        case "pipeline.step.cancelled": return Theme.muted
        default:
            return record.event.level == .error ? Theme.red : Theme.muted
        }
    }

    private func recordSymbol(_ record: RunRecord) -> String {
        switch record.event.code {
        case "pipeline.step.succeeded": return "checkmark"
        case "pipeline.step.started": return "play.fill"
        case "pipeline.step.failed": return "exclamationmark"
        case "pipeline.step.cancelled", "pipeline.cancellation.requested": return "stop.fill"
        case "engine.legacy.warning": return "exclamationmark.triangle.fill"
        case "engine.legacy.log": return "ellipsis"
        default: return "circle.fill"
        }
    }

    private func copyDiagnostics() {
        let text = app.runRecords.map { record in
            let time = record.timestamp.formatted(date: .omitted, time: .standard)
            let values = record.event.values
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            let technical = record.event.technicalText ?? ""
            return "\(time) [\(record.stepID ?? "run")] \(record.event.code) \(values) \(technical)"
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct RunStateBadge: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// 竖向时间线：四步串在一条竖线上，进行中的那步就地展开进度。
struct PipelineTimeline: View {
    let steps: [PipelineStep]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                TimelineRow(step: step, order: idx + 1, isLast: idx == steps.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TimelineRow: View {
    @Environment(\.accentPalette) private var palette
    let step: PipelineStep
    let order: Int
    let isLast: Bool

    private var bottomPad: CGFloat { isLast ? 0 : (step.status == .running ? 12 : 7) }

    private var statusLabel: String {
        switch step.status {
        case .idle: return "待执行"
        case .running: return "进行中"
        case .success: return "已完成"
        case .failed: return "需查看"
        }
    }

    private var statusColor: Color {
        switch step.status {
        case .idle: return Theme.muted
        case .running: return palette.accent
        case .success: return Theme.green
        case .failed: return Theme.red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            node.frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(step.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(step.status == .idle ? Theme.muted : Theme.fg)

                    Spacer(minLength: 12)

                    Text(statusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor.opacity(step.status == .idle ? 0.08 : 0.12))
                        .clipShape(Capsule())
                }

                Text(step.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)

                if step.status == .running {
                    if !step.subs.isEmpty {
                        ForEach(step.subs) { sub in subRow(sub) }
                    } else if let p = step.progress {
                        ProgressView(value: p).tint(palette.accent).padding(.top, 4)
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
        .padding(.horizontal, 10)
        .padding(.vertical, step.status == .running ? 10 : 7)
        .background {
            if step.status == .running {
                RoundedRectangle(cornerRadius: 10)
                    .fill(palette.accentSoft.opacity(0.45))
            }
        }
        // 连接线用 overlay 画在节点正下方，高度自然等于本行内容高度——不会把行撑大。
        .overlay(alignment: .topLeading) {
            if !isLast {
                Rectangle().fill(Theme.line).frame(width: 2)
                    .padding(.top, 31).padding(.leading, 21)
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
                ProgressView(value: sub.progress ?? 0).tint(palette.accent)
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
        case .idle:
            ZStack {
                Circle().fill(Theme.panel2)
                Circle().stroke(Theme.line, lineWidth: 1)
                Text("\(order)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.muted)
            }
        case .running:
            ZStack {
                Circle().fill(palette.accentSoft)
                Circle().stroke(palette.accentLine.opacity(0.9), lineWidth: 1)
                ProgressView().controlSize(.mini).tint(palette.accent)
            }
        case .success:
            ZStack {
                Circle().fill(Theme.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .failed:
            ZStack {
                Circle().fill(Theme.red.opacity(0.16))
                Circle().stroke(Theme.red.opacity(0.65), lineWidth: 1)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.red)
            }
        }
    }
}

// AI / 单独运行步骤前的二次确认弹窗，可勾「以后默认同意」。
struct ConfirmSheet: View {
    @Environment(\.accentPalette) private var palette
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
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(palette.accent)
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

// 界面：菜单栏面板、账号行、token 图表、设置窗口。
// 单列布局，不加侧边栏和筛选器。

import AppKit
import SwiftUI

// MARK: - 面板

final class PanelNavigation: ObservableObject {
    @Published var showingSettings = false
    @Published var dashboardHeight: CGFloat?
}

private struct PanelSizePreference: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct ContentView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var tokens = TokenStats.shared
    @ObservedObject var codexAccounts = CodexAccounts.shared
    var isPreview = false
    @StateObject private var navigation = PanelNavigation()
    var initialSettings = false

    var viewportHeight: CGFloat? = nil

    var panelHeight: CGFloat {
        let limit = viewportHeight ?? min(720, max(200, (NSScreen.main?.visibleFrame.height ?? 880) - 64))
        if navigation.showingSettings { return limit }
        let initial = CGFloat(store.accounts.count) * 110 + CGFloat(isPreview ? 1 : codexAccounts.stores.count) * 105 + 95
        return min(limit, max(160, navigation.dashboardHeight ?? initial))
    }

    var body: some View {
        Group {
            if navigation.showingSettings {
                VStack(spacing: 0) {
                    HStack {
                        Button { navigation.showingSettings = false } label: {
                            Label("返回仪表", systemImage: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                        Spacer()
                        Text("设置").font(.headline)
                        Spacer()
                        Button("完成") { navigation.showingSettings = false }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(14)
                    Divider()
                    SettingsView(store: store)
                }
            } else {
                dashboard
            }
        }
        .frame(width: 360, height: panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onPreferenceChange(PanelSizePreference.self) { metrics in
            if let header = metrics["header"], let content = metrics["content"] {
                let height = ceil(header + content + 1)
                if abs((navigation.dashboardHeight ?? 0) - height) > 1 { navigation.dashboardHeight = height }
            }
        }
        .onDisappear { navigation.showingSettings = false }
        .onAppear {
            navigation.showingSettings = initialSettings
            if !isPreview {
                tokens.reload()
                Task { await store.identifyActive() }
            }
        }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: PanelSizePreference.self, value: ["header": geo.size.height])
                })
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if isPreview {
                        CodexQuotaSection(store: .preview)
                    } else {
                        ForEach(codexAccounts.stores) { codex in
                            CodexQuotaSection(store: codex)
                        }
                    }
                    Divider()
                    HStack {
                        Text("Claude").font(.headline)
                        Spacer()
                    }
                    if store.accounts.isEmpty {
                        Text("还没有账号").font(.headline)
                        Text("到设置中添加 Claude 账号。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(store.accounts) { account in
                            AccountRow(
                                account: account,
                                snapshot: store.shownSnapshot(account),
                                isActive: store.isActive(account),
                                hasCredential: store.hasCredential(account),
                                warning: store.dataWarning(account),
                                lastAttempt: store.lastAttempts[account.id],
                                nextAttempt: store.nextAttempt(account),
                                onSwitch: { store.switchTo(account) },
                                onLogin: { LoginController.shared.present(for: account) },
                                onAdopt: { store.adoptLiveCredential(for: account) },
                                onRemove: { store.remove(account) }
                            )
                            if account.id != store.accounts.last?.id { Divider() }
                        }
                    }
                    if settings.showTokenChart && tokens.totals.all > 0 {
                        Divider()
                        TokenSection()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: PanelSizePreference.self, value: ["content": geo.size.height])
                })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
            Text("QuotaBar").font(.headline)
            if settings.paused {
                Text("已暂停").font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button {
                store.refreshNow()
                codexAccounts.refreshNow()
            } label: {
                if store.refreshBusy || codexAccounts.refreshing {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("刷新额度")
            .help("立即重新获取额度；接口限流期间需等待")
            .disabled(store.refreshBusy || codexAccounts.refreshing || store.switching || store.verifying)
            Button {
                navigation.showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("打开设置")
            .help("设置")
        }

        }
    }


}

// MARK: - 账号行

struct AccountRow: View {
    let account: Account
    let snapshot: Snapshot?
    let isActive: Bool
    let hasCredential: Bool
    let warning: String?
    let lastAttempt: Date?
    let nextAttempt: Date?
    let onSwitch: () -> Void
    let onLogin: () -> Void
    let onAdopt: () -> Void
    let onRemove: () -> Void

    private func bar(_ label: String, _ window: UsageWindow?, now: Date) -> some View {
        QuotaUsageBar(label: label, usedPercent: window?.utilization, resetsAt: window?.resetsAt, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(account.name).font(.subheadline.weight(.semibold))
                if isActive {
                    Text("当前").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                } else if !account.hasSession && !hasCredential {
                    Text("未登录").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let plan = snapshot?.plan {
                    Text(plan).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !isActive && hasCredential {
                    Button("切换") { onSwitch() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if let warning {
                Text(warning).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let snap = snapshot, snap.error == nil {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(snap.quotaWindows) { quota in
                            if let title = quota.title {
                                Text(title).font(.caption.weight(.medium))
                            }
                            bar(quota.label, quota.window, now: context.date)
                        }
                    }
                }
            } else if let snap = snapshot, let error = snap.error {
                Text(error).font(.caption2).foregroundStyle(.orange)
            } else {
                Text("尚未取到数据").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Token 区

struct QuotaUsageBar: View {
    let label: String
    let usedPercent: Double?
    let resetsAt: Date?
    let now: Date

    var body: some View {
        let pct = usedPercent ?? 0
        let tone: Color = pct >= 95 ? .red : (pct >= 80 ? .orange : .green)
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 38, alignment: .leading)
            ProgressView(value: min(max(pct, 0), 100), total: 100)
                .tint(tone).frame(minWidth: 24, maxWidth: .infinity)
            Text(usedPercent.map { "\(Int($0))%" } ?? "-")
                .font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
            Text(resetCountdown(resetsAt, now: now))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85).fixedSize(horizontal: true, vertical: false)
                .help(resetsAt == nil ? "接口未提供重置时间" : "重置剩余时间：" + resetCountdown(resetsAt, now: now))
        }
        .accessibilityElement(children: .combine)
    }
}

struct CodexQuotaSection: View {
    @ObservedObject var store: CodexQuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("GPT").font(.headline)
                Spacer()
                if let plan = store.snapshot?.plan {
                    Text(["prolite": "Pro Lite", "plus": "Plus", "pro": "Pro", "free": "Free",
                          "business": "Business", "team": "Team", "enterprise": "Enterprise", "edu": "Edu"][plan] ?? plan)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let snapshot = store.snapshot {
                Text(snapshot.email).font(.caption).textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(snapshot.windows) { window in
                            if window.bucket != "Codex" {
                                Text(window.bucket).font(.caption.weight(.medium))
                            }
                            QuotaUsageBar(label: window.label, usedPercent: window.usedPercent,
                                          resetsAt: window.resetsAt, now: context.date)
                        }
                        if context.date.timeIntervalSince(snapshot.fetchedAt) > 1800 {
                            Text("历史数据，等待成功刷新").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            } else if store.error == nil {
                Text(store.refreshing ? "正在获取额度…" : "等待获取 Codex 额度")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.error {
                Text(error + (store.snapshot == nil ? "" : "；保留上次数据"))
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = store.message, message.contains("重试") {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct TokenSection: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var tokens = TokenStats.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Token 用量").font(.caption.weight(.semibold))
                Spacer()
                Picker("", selection: Binding(
                    get: { settings.chartStyle.rawValue },
                    set: { settings.chartStyle = ChartStyle(rawValue: $0) ?? .wave })) {
                    ForEach(ChartStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.mini).fixedSize()
            }

            if settings.chartStyle == .wave {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { settings.chartGranularity.rawValue },
                        set: { settings.chartGranularity = ChartGranularity(rawValue: $0) ?? .day })) {
                        ForEach(ChartGranularity.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.mini).fixedSize()
                    Spacer()
                    Text("今日 \(formatTokens(tokens.totals.today))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                WaveChart(points: tokens.series(for: settings.chartGranularity))
                    .frame(height: 64)
            } else {
                HeatmapChart(points: tokens.heat)
                    .frame(height: 96)
                Text("最近 17 周 · 今日 \(formatTokens(tokens.totals.today)) · 本周 \(formatTokens(tokens.totals.week))")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text("累计 \(formatTokens(tokens.totals.all))").help(tokens.source)
                Text("· \(tokens.totals.requests) 次请求")
                Spacer()
                if tokens.scanning {
                    Text("统计中…")
                } else if let stamp = tokens.lastScan {
                    Text(stamp.formatted(date: .omitted, time: .shortened))
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct WaveChart: View {
    let points: [TokenPoint]

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(points.map(\.total).max() ?? 1, 1)
            let width = geo.size.width
            let height = geo.size.height
            let step = points.count > 1 ? width / CGFloat(points.count - 1) : width

            ZStack(alignment: .bottomLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    for (index, point) in points.enumerated() {
                        let x = CGFloat(index) * step
                        let ratio = CGFloat(point.total) / CGFloat(maxValue)
                        let y = height - ratio * (height - 4) - 1
                        if index == 0 {
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    path.addLine(to: CGPoint(x: CGFloat(points.count - 1) * step, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35),
                                              Color.accentColor.opacity(0.04)],
                                     startPoint: .top, endPoint: .bottom))

                Path { path in
                    for (index, point) in points.enumerated() {
                        let x = CGFloat(index) * step
                        let ratio = CGFloat(point.total) / CGFloat(maxValue)
                        let y = height - ratio * (height - 4) - 1
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
    }
}

struct HeatmapChart: View {
    let points: [TokenPoint]

    var body: some View {
        let maxValue = max(points.map(\.total).max() ?? 1, 1)
        let columns = max(1, (points.count + 6) / 7)
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let cell = min((geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns),
                           (geo.size.height - spacing * 6) / 7)
            HStack(alignment: .top, spacing: spacing) {
                ForEach(0..<columns, id: \.self) { column in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            let index = column * 7 + row
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(at: index, maxValue: maxValue))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
    }

    private func color(at index: Int, maxValue: Int) -> Color {
        guard index < points.count else { return Color.secondary.opacity(0.06) }
        let value = points[index].total
        if value == 0 { return Color.secondary.opacity(0.10) }
        let ratio = Double(value) / Double(maxValue)
        let opacity = 0.25 + 0.75 * min(1, max(0.15, ratio))
        return Color.accentColor.opacity(opacity)
    }
}

// MARK: - 面板内设置

struct SettingsView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var codexAccounts = CodexAccounts.shared
    @ObservedObject var updater = AppUpdater.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("GPT 账号") {
                    ForEach(codexAccounts.stores) { codex in
                        CodexAccountSettingsRow(store: codex, accounts: codexAccounts)
                    }
                    HStack {
                        Button("添加 GPT 账号") { codexAccounts.addAccount() }
                            .disabled(codexAccounts.signingIn)
                        if codexAccounts.signingIn {
                            ProgressView().controlSize(.small)
                            Button("取消") { codexAccounts.cancelLogin() }
                        }
                    }
                    if let note = codexAccounts.loginNote {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                group("Claude 账号") {
                    ForEach(store.accounts) { account in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(account.name).font(.caption.weight(.medium))
                                Spacer()
                                if let plan = store.shownSnapshot(account)?.plan {
                                    Text(plan).font(.caption).foregroundStyle(.secondary)
                                }
                                Menu {
                                    Button("重新登录") { LoginController.shared.present(for: account) }
                                    Button("保存当前凭据") { store.adoptLiveCredential(for: account) }
                                    Button("移除", role: .destructive) { store.remove(account) }
                                } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            }
                            if let email = account.email {
                                Text(email).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    Button("添加 Claude 账号") { LoginController.shared.present() }
                }
                group("面板") {
                    Toggle("显示 Token 图表", isOn: $settings.showTokenChart)
                }

                group("刷新") {
                    Toggle("暂停后台刷新", isOn: $settings.paused)
                    Text("暂停后仅手动查询额度，当前账号识别仍会更新。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Toggle("电池供电时降频", isOn: $settings.adaptiveRefresh)
                }

                group("通知") {
                    Toggle("开启系统通知", isOn: $settings.notifyEnabled)
                        .onChange(of: settings.notifyEnabled) { _, enabled in
                            if enabled { Notifier.shared.prepare(userInitiated: true) }
                        }
                    if settings.notifyEnabled {
                        slider("5 小时阈值", value: $settings.thresholdFive)
                        slider("7 天阈值", value: $settings.thresholdSeven)
                        Toggle("切换账号后提醒", isOn: $settings.notifyOnSwitch)
                        Text("没收到通知时，到「系统设置 → 通知」里允许 QuotaBar。未获授权时跳过通知，后台不会再次请求授权。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                group("集成") {
                    Toggle("切换后重开 IDE", isOn: $settings.autoRestartIDE)
                    Text("会关闭并重新打开 VS Code / Cursor / Windsurf / JetBrains。有未保存文档时会跳过。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Toggle("保持网页登录态", isOn: $settings.keepAliveEnabled)
                }

                group("软件更新") {
                    Text("QuotaBar \(appVersion)").font(.caption).foregroundStyle(.secondary)
                    Toggle("自动检查新版本", isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks))
                        .disabled(!updater.enabled)
                    Toggle("自动下载并安装更新", isOn: Binding(get: { updater.automaticallyInstalls }, set: updater.setAutomaticInstallation))
                        .disabled(!updater.enabled)
                    Button("检查更新") { updater.check() }.disabled(!updater.canCheck)
                    Text(updater.note).font(.caption2).foregroundStyle(.secondary)
                }
                group("诊断") {
                    HStack {
                        Button(store.verifying ? "正在诊断…" : "运行诊断") { store.verifyAll() }
                            .disabled(store.verifying || store.refreshBusy || store.switching || codexAccounts.refreshing || codexAccounts.signingIn)
                        if store.verifying { ProgressView().controlSize(.small) }
                    }
                    ForEach(store.verifyResults) { result in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(result.name, systemImage: result.usageOK ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(result.usageOK ? Color.green : Color.orange)
                            Text(result.note).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let note = store.manualRefreshMessage {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let note = store.switchNote {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("版本 \(appVersion)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("导出诊断") {
                            if let url = store.exportDiagnostics() {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        Button("打开日志") {
                            NSWorkspace.shared.open(logDirectory)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Button("退出 QuotaBar") { NSApp.terminate(nil) }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ title: String, value: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Int($0) }), in: 50...100, step: 5)
            Text("\(value.wrappedValue)%")
                .font(.caption.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
    }
}

struct CodexAccountSettingsRow: View {
    @ObservedObject var store: CodexQuotaStore
    @ObservedObject var accounts: CodexAccounts

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.snapshot?.email ?? (store.id == "current" ? "GPT 当前登录" : "新 GPT 账号"))
                    .font(.caption).textSelection(.enabled)
                if store.id == "current" {
                    Text("跟随 Codex 登录").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.id != "current" {
                Button("移除") { accounts.remove(store) }.controlSize(.small).disabled(store.refreshing)
            }
        }
    }
}


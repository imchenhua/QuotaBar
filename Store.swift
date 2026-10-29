// 轮询与状态。
//
// 独立请求 cookie / OAuth；ClaudeBar 仅用于用户发起的一次性迁移。

import AppKit
import Foundation

struct VerifyResult: Identifiable {
    let id: String
    let name: String
    let hasCredential: Bool
    let refreshable: Bool
    let usageOK: Bool
    let note: String
}

@MainActor
final class QuotaStore: ObservableObject {
    static let shared = QuotaStore()

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var snapshots: [String: Snapshot] = [:]
    @Published private(set) var lastRound: Date?
    @Published private(set) var lastGood: [String: Snapshot] = [:]
    @Published private(set) var slots: [String: CredentialSlot] = [:]
    @Published private(set) var activeFingerprint: String?
    @Published private(set) var activeKey: String?
    @Published private(set) var activeIdentityNote = "正在识别 Claude Code 账号…"
    @Published private(set) var activeIdentitySource = ""
    @Published private(set) var activeIdentityCheckedAt: Date?

    @Published var switchNote: String?
    @Published var menuBarOrg: String = UserDefaults.standard.string(forKey: "menuBarOrg") ?? ""

    @Published private(set) var verifyResults: [VerifyResult] = []
    @Published private(set) var verifying = false
    @Published private(set) var lastVerify: Date?
    @Published private(set) var usingClaudeBarCache = false
    @Published private(set) var lastFingerprintState = ""

    private var consecutiveFailures: [String: Int] = [:]
    private var nextEligible: [String: Date] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var manualRefreshPending = false
    @Published private(set) var manualRefreshMessage: String?
    var refreshBusy: Bool { refreshing || manualRefreshPending }
    @Published private(set) var switching = false
    @Published private(set) var lastAttempts: [String: Date] = [:]
    private var loop: Task<Void, Never>?
    private var identityLoop: Task<Void, Never>?
    private var identityCheckInFlight = false
    private var lastIdentityAttempt = Date.distantPast
    private var identityRevision = 0
    private let pollStateURL = Paths.configDir.appendingPathComponent("poll-state.json")
    private struct PollState: Codable {
        var nextEligible: [String: Date]
        var lastAttempts: [String: Date]
        var failures: [String: Int]
        var snapshots: [String: Snapshot]?
    }
    private func savePollState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(PollState(nextEligible: nextEligible,
                            lastAttempts: lastAttempts, failures: consecutiveFailures, snapshots: snapshots)) {
            try? privateWrite(data, to: pollStateURL)
        }
    }
    private func restorePollState() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: pollStateURL),
           let state = try? decoder.decode(PollState.self, from: data) {
            nextEligible = state.nextEligible
            lastAttempts = state.lastAttempts
            consecutiveFailures = state.failures
            snapshots = state.snapshots ?? [:]
        }
    }
    private var lastKeepAlive: Date = .distantPast
    /// 已经就阈值提醒过的窗口，回到阈值下会清掉。
    private var crossed: Set<String> = []
    private var diagnosticMode = false

    nonisolated private static let importerPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("bin/quotabar-import.py").path

    init(preview: Bool = false) {
        if preview {
            accounts = [
                Account(name: "Personal", email: "personal@example.invalid", org: "fixture-1", sessionKey: "fixture"),
                Account(name: "Work", email: "work@example.invalid", org: "fixture-2", sessionKey: ""),
                Account(name: "Lab", email: "lab@example.invalid", org: "fixture-3", sessionKey: "")
            ]
            let now = Date()
            for (i, account) in accounts.enumerated() {
                lastGood[account.id] = Snapshot(
                    fiveHour: i == 0 ? nil : UsageWindow(utilization: i == 2 ? 68 : 0, resetsAt: now.addingTimeInterval(7200)),
                    sevenDay: UsageWindow(utilization: i == 2 ? 78 : 100, resetsAt: now.addingTimeInterval(259200)),
                    fetchedAt: now.addingTimeInterval(-Double(i) * 1200), error: nil,
                    source: i == 0 ? "cookie" : "历史数据", plan: ["Max 5x", "Pro", "Max 20x"][i])
                lastAttempts[account.id] = now
                nextEligible[account.id] = now.addingTimeInterval(900)
            }
            lastRound = now
            menuBarOrg = ""
            activeKey = CredentialStore.key(for: accounts[2])
            activeIdentityNote = ""
            activeIdentitySource = "测试数据"
            activeIdentityCheckedAt = now
        } else {
            accounts = Paths.loadAccounts()
            lastGood = Paths.loadSnapshots()
            slots = CredentialStore.load()
        }
    }

    // MARK: 展示

    func setMenuBarOrg(_ org: String) {
        menuBarOrg = org
        UserDefaults.standard.set(org, forKey: "menuBarOrg")
    }

    var activeAccount: Account? {
        guard let key = activeKey, let checked = activeIdentityCheckedAt,
              Date().timeIntervalSince(checked) < 90 else { return nil }
        return accounts.first { CredentialStore.key(for: $0) == key }
    }

    func shownSnapshot(_ account: Account) -> Snapshot? {
        let live = snapshots[account.id]
        if let live, live.error == nil { return live }
        return lastGood[account.id] ?? live
    }

    func dataWarning(_ account: Account) -> String? {
        if !account.hasSession && !hasCredential(account) {
            return "需要重新登录；历史额度保留，尚未独立更新"
        }
        if let error = snapshots[account.id]?.error { return error + "；保留上次成功数据" }
        guard let snap = shownSnapshot(account) else { return "尚未成功获取额度" }
        if snap.source == "claudebar" { return "迁移的 ClaudeBar 历史数据，等待独立验证" }
        let age = Date().timeIntervalSince(snap.fetchedAt)
        if age < -60 || age > 1800 { return "数据已过期，等待成功更新" }
        return nil
    }

    func nextAttempt(_ account: Account) -> Date? { nextEligible[account.id] }

    var displayAccount: Account? {
        if !menuBarOrg.isEmpty, let pinned = accounts.first(where: { $0.org == menuBarOrg }) {
            return pinned
        }
        return activeAccount ?? accounts.first
    }

    var menuBarText: String {
        guard let shown = displayAccount else { return "-" }
        guard let snap = shownSnapshot(shown) else { return "…" }
        if snap.error != nil { return "-" }
        let five = snap.fiveHour?.utilization.map { Int($0) }
        let seven = snap.sevenDay?.utilization.map { Int($0) }
        func pct(_ value: Int?) -> String { value.map { "\($0)%" } ?? "-" }
        let prefix = (dataWarning(shown) == nil ? "" : "⚠ ") + shown.name + " "
        switch AppSettings.shared.menuBarStyle {
        case .minimal:
            return prefix + pct(seven)
        case .standard:
            return prefix + "\(pct(five)) · \(pct(seven))"
        case .detailed:
            return prefix + "5h \(pct(five))  7d \(pct(seven))"
        }
    }

    var menuBarSymbol: String {
        guard let shown = displayAccount, let snap = shownSnapshot(shown) else { return "hourglass" }
        if dataWarning(shown) != nil { return "exclamationmark.triangle" }
        if snap.error != nil { return "gauge" }
        guard let pct = snap.sevenDay?.utilization else { return "gauge" }
        if pct >= 95 { return "gauge.with.dots.needle.100percent" }
        if pct >= 80 { return "gauge.with.dots.needle.67percent" }
        return "gauge.with.dots.needle.33percent"
    }

    var menuBarTooltip: String {
        guard let shown = displayAccount else { return "QuotaBar" }
        var lines = ["Claude Code 当前：" + (activeAccount?.name ?? "未识别"), "额度显示：" + shown.name]
        if let snap = shownSnapshot(shown), snap.error == nil {
            lines.append("5h \(snap.fiveHour?.utilization.map { "\(Int($0))%" } ?? "-")")
            lines.append("7d \(snap.sevenDay?.utilization.map { "\(Int($0))%" } ?? "-")")
            if let reset = snap.sevenDay?.resetsAt {
                lines.append("7d 重置 \(reset.formatted(date: .abbreviated, time: .shortened))")
            }
        } else {
            lines.append("暂无数据")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 账号与凭据

    func reloadConfig() {
        accounts = Paths.loadAccounts()
        snapshots = snapshots.filter { key, _ in accounts.contains { $0.id == key } }
        // 这里不清退避账本：重读配置每轮都会发生，清了就等于每轮重撞一次限流。
    }

    func remove(_ account: Account) {
        guard !refreshing, !switching, !verifying else {
            switchNote = "正在处理账号，请稍后移除"; return
        }
        guard Paths.remove(org: account.org) else { switchNote = "账号保存失败，未移除"; return }
        reloadConfig()
        let key = CredentialStore.key(for: account)
        if !accounts.contains(where: { CredentialStore.key(for: $0) == key }) {
            var current = CredentialStore.load()
            current.removeValue(forKey: key)
            if CredentialStore.save(current) { SecretVault.remove(key: "oauth:" + key) }
        }
        snapshots.removeValue(forKey: account.id)
        lastGood.removeValue(forKey: account.id)
        lastAttempts.removeValue(forKey: account.id)
        nextEligible.removeValue(forKey: account.id)
        consecutiveFailures.removeValue(forKey: account.id)
        Paths.saveSnapshots(lastGood)
        savePollState()
        reloadCredentialState()
        log("已移除账号 \(account.name)")
    }

    func isActive(_ account: Account) -> Bool {
        activeAccount?.id == account.id
    }

    func hasCredential(_ account: Account) -> Bool {
        slots[CredentialStore.key(for: account)].flatMap { accessToken(of: $0.payload) } != nil
    }

    func reloadCredentialState() {
        slots = CredentialStore.load()
        if let live = KeychainCredentials.readLive(), let fingerprint = credentialFingerprint(live),
           let known = slots.first(where: { $0.value.fingerprint == fingerprint }) {
            activeFingerprint = fingerprint
            activeKey = known.key
            activeIdentitySource = "凭据验证"
            activeIdentityCheckedAt = Date()
            activeIdentityNote = ""
        } else {
            Task { await identifyActive() }
        }
    }

    /// 只有用户点「切换」时才会走到这里，任何情况下都不自动切。
    func switchTo(_ account: Account) {
        guard !switching, !refreshing, !verifying else {
            switchNote = "正在处理账号，请稍后再试"; return
        }
        guard let original = slots[CredentialStore.key(for: account)],
              accessToken(of: original.payload) != nil else {
            LoginController.shared.present(for: account); return
        }
        switching = true
        identityRevision += 1
        Task { @MainActor in
            defer { switching = false }
            var payload = original.payload
            if expiresAt(of: payload).map({ $0 < Date().addingTimeInterval(300) }) ?? true {
                guard let refreshed = await refreshCredential(payload) else {
                    switchNote = "凭据续期失败，请重新登录 \(account.name)"; return
                }
                payload = refreshed
            }
            guard let token = accessToken(of: payload),
                  let profile = await fetchProfile(token: token),
                  let email = profile.account.email?.lowercased(),
                  email == account.email?.lowercased(),
                  profile.organization?.uuid.lowercased() == account.org.lowercased() else {
                switchNote = "无法确认目标账号身份，未切换。请重新登录"; return
            }
            do {
                try await Task.detached { try KeychainCredentials.switchLive(payload) }.value
                guard CredentialStore.store(payload: payload, email: email, for: account) else {
                    switchNote = "系统凭据已切换，但本地凭据保存失败，请检查登录状态"; return
                }
                activeKey = CredentialStore.key(for: account)
                activeFingerprint = credentialFingerprint(payload)
                activeIdentitySource = "凭据验证"
                activeIdentityCheckedAt = Date()
                activeIdentityNote = ""
                reloadCredentialState()
                switchNote = "已切到 \(account.name)，新启动的 Claude Code 会读取新凭据"
                log("手动切换成功 → \(account.name)")
                if AppSettings.shared.notifyOnSwitch {
                    Notifier.shared.post(key: "switch-\(account.id)", title: "已切换到 \(account.name)",
                                         body: "已有 Claude Code 会话需重启后生效")
                }
                restartIDEsIfNeeded()
            } catch {
                switchNote = "\(error)"
                log("手动切换未完成；不会后台重试")
            }
        }
    }

    private func restartIDEsIfNeeded() {
        guard AppSettings.shared.autoRestartIDE else {
            if !IDERestart.runningClients().isEmpty {
                switchNote = "已切换。IDE 正在跑，重启后才会读到新凭据"
            }
            return
        }
        let running = IDERestart.runningClients()
        guard !running.isEmpty else { return }
        Task { @MainActor in
            let touched = await IDERestart.restart()
            if !touched.isEmpty {
                switchNote = "已切换，并重开了 \(touched.joined(separator: "、"))"
            }
        }
    }

    func adoptLiveCredential(for account: Account) {
        guard !refreshing, !switching, !verifying else { return }
        guard let live = KeychainCredentials.readLive() else {
            switchNote = "系统里没有可用的凭据"
            return
        }
        Task { @MainActor in
            guard let token = accessToken(of: live),
                  let profile = await fetchProfile(token: token),
                  let email = profile.account.email?.lowercased(),
                  email == account.email?.lowercased(),
                  profile.organization?.uuid.lowercased() == account.org.lowercased() else {
                switchNote = "未能验证系统凭据属于这个账号，未保存"; return
            }
            CredentialStore.store(payload: live, email: account.email ?? account.name, for: account)
            reloadCredentialState()
            switchNote = "已把系统当前凭据记到 \(account.name)"
            log("记录当前凭据 → \(account.name)")
            refreshNow()
        }
    }

    /// 启动时核一遍每个槽：凭据里的邮箱和槽名对不上就丢掉，
    /// 免得拿别人家的额度当成自己的显示。
    func verifySlots() async {
        var current = CredentialStore.load()
        var changed = false
        for (key, slot) in current where !key.hasPrefix("org:") {
            guard let token = accessToken(of: slot.payload),
                  let profile = await fetchProfile(token: token),
                  let email = profile.account.email?.lowercased(), !email.isEmpty
            else { continue }
            if email != key {
                current.removeValue(forKey: key)
                changed = true
                log("槽 \(key) 的凭据其实属于 \(email)，已移除")
            }
        }
        if changed {
            CredentialStore.save(current)
            slots = current
        }
    }

    // MARK: 体检

    /// 一个入口检查所有 Claude / GPT 账号；不切换账号，不触发登录。
    func verifyAll() {
        Task { await verifyAllNow() }
    }

    func verifyAllNow() async {
        let gpt = CodexAccounts.shared
        guard !verifying, !refreshBusy, !switching, !gpt.refreshing, !gpt.signingIn,
              !LoginController.shared.isPresenting else { return }
        verifying = true
        verifyResults = []
        do {
            let started = Date()
            _ = await runRound(manual: true)
            verifyResults = accounts.map { account in
                let slot = slots[CredentialStore.key(for: account)].flatMap { accessToken(of: $0.payload) == nil ? nil : $0 }
                let snap = shownSnapshot(account)
                let fresh = snap.map { $0.fetchedAt >= started } ?? false
                let ok = fresh && dataWarning(account) == nil && snap?.source != "claudebar"
                var note = dataWarning(account) ?? (fresh ? "登录与额度读取正常" : "本次未读取到新额度")
                if let gate = nextEligible[account.id], gate > Date(), !ok {
                    note += "；下次尝试 " + gate.formatted(date: .omitted, time: .shortened)
                }
                if slot == nil { note += "；切换账号仍需 OAuth 登录" }
                else { note += "；续期在到期时验证" }
                return VerifyResult(id: "claude-" + account.id, name: "Claude · " + account.name,
                    hasCredential: slot != nil, refreshable: slot != nil,
                    usageOK: ok, note: note)
            }
            for store in gpt.stores {
                let started = Date()
                await store.refresh(manual: true)
                let snapshot = store.snapshot
                let fresh = snapshot.map { $0.fetchedAt >= started } ?? false
                let ok = fresh && store.error == nil
                let note = store.error ?? (fresh ? "登录与额度读取正常" : (store.message ?? "本次未读取到新额度，请稍后重试"))
                verifyResults.append(VerifyResult(id: "gpt-" + store.id,
                    name: "GPT · " + (snapshot?.email ?? "未识别账号"),
                    hasCredential: snapshot != nil, refreshable: snapshot != nil, usageOK: ok, note: note))
            }
            lastVerify = Date()
            verifying = false
            log("统一诊断完成：\(verifyResults.count) 个 Claude / GPT 账号")
        }
    }

    // MARK: 轮询

    func start() {
        guard loop == nil else { return }
        restorePollState()
        CredentialStore.migrateLegacyBackups()
        // 升级时仅迁移一次历史数值；保留原始获取时间，绝不作为独立取数成功。
        if !FileManager.default.fileExists(atPath: Paths.configDir.appendingPathComponent("migration-v2.1").path) {
            for account in accounts {
                if let historical = ClaudeBarData.snapshot(org: account.org, maxAge: .infinity),
                   historical.fetchedAt > (lastGood[account.id]?.fetchedAt ?? .distantPast) {
                    lastGood[account.id] = historical
                }
            }
            Paths.saveSnapshots(lastGood)
            try? privateWrite(Data("complete".utf8), to: Paths.configDir.appendingPathComponent("migration-v2.1"))
        }
        if AppSettings.shared.notifyEnabled { Notifier.shared.prepare() }
        TokenStats.shared.reload()
        identityLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.identifyActive()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let cooldown = await self?.runRound() ?? 0
                var seconds = max(120, cooldown)
                if AppSettings.shared.paused { seconds = 30 }
                if AppSettings.shared.adaptiveRefresh,
                   Power.onBattery() || Power.lowPowerMode() {
                    seconds = max(seconds * 2, 900)
                }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
    }

    func identifyActive() async {
        guard !identityCheckInFlight, !switching,
              Date().timeIntervalSince(lastIdentityAttempt) >= 2 else { return }
        identityCheckInFlight = true
        lastIdentityAttempt = Date()
        let revision = identityRevision
        defer { identityCheckInFlight = false }
        let live = await Task.detached { KeychainCredentials.readLive() }.value
        guard revision == identityRevision, !switching else { return }
        if let live, let fingerprint = credentialFingerprint(live) {
            if let known = slots.first(where: { $0.value.fingerprint == fingerprint }) {
                activeKey = known.key
                activeFingerprint = fingerprint
                activeIdentitySource = "凭据验证"
                activeIdentityCheckedAt = Date()
                activeIdentityNote = ""
                return
            }
            if let token = accessToken(of: live), let profile = await fetchProfile(token: token) {
                guard revision == identityRevision, !switching else { return }
                if let account = accounts.first(where: {
                    $0.email?.lowercased() == profile.account.email?.lowercased()
                    && $0.org.lowercased() == profile.organization?.uuid.lowercased()
                }) {
                    _ = CredentialStore.store(payload: live, email: account.email ?? account.name, for: account)
                    slots = CredentialStore.load()
                    activeKey = CredentialStore.key(for: account)
                    activeFingerprint = fingerprint
                    activeIdentitySource = "凭据验证"
                    activeIdentityCheckedAt = Date()
                    activeIdentityNote = ""
                    return
                }
            }
            activeKey = nil
            activeFingerprint = fingerprint
            activeIdentityNote = "当前凭据暂无法对应到已保存账号"
            activeIdentityCheckedAt = Date()
            return
        }
        // Use the supported CLI identity command when its private Keychain entry is inaccessible.
        let status = await Task.detached { ClaudeCLIIdentity.status() }.value
        guard revision == identityRevision, !switching else { return }
        activeFingerprint = nil
        activeIdentityCheckedAt = Date()
        activeIdentitySource = "Claude Code 状态"
        if let status, let account = accountMatchingCLIStatus(status, accounts: accounts) {
            activeKey = CredentialStore.key(for: account)
            activeIdentityNote = ""
        } else {
            activeKey = nil
            if let status, !status.loggedIn { activeIdentityNote = "Claude Code 尚未登录" }
            else if let status, let method = status.authMethod, method != "claude.ai" {
                activeIdentityNote = "Claude Code 使用 API 凭据"
            } else { activeIdentityNote = "暂未识别到已保存的 Claude Code 账号" }
        }
    }

    func didAuthenticate(_ account: Account) {
        reloadConfig()
        reloadCredentialState()
        if snapshots[account.id]?.error?.contains("429") != true {
            nextEligible.removeValue(forKey: account.id)
            consecutiveFailures.removeValue(forKey: account.id)
            snapshots.removeValue(forKey: account.id)
        }
        savePollState()
        refreshNow()
    }

    func refreshNow() {
        guard !refreshBusy, !switching, !verifying else { return }
        manualRefreshPending = true
        manualRefreshMessage = "正在刷新额度…"
        Task {
            defer { manualRefreshPending = false }
            _ = await runRound(manual: true)
            await identifyActive()
            TokenStats.shared.reload()
        }
    }

    func importCookies() async -> Bool {
        guard !refreshing, !switching else { return false }
        refreshing = true
        defer { refreshing = false }
        let imported = await Task.detached(priority: .utility) { AccountImport.read() }.value
        guard let imported else { switchNote = "迁移失败，原账号及凭据已保留"; return false }
        let current = mergeImportedAccounts(Paths.loadAccounts(), imported)
        guard Paths.saveAccounts(current) else { return false }
        reloadConfig()
        switchNote = "已合并迁移账号；额度将通过独立接口验证"
        log("手动迁移完成，保留本地账号与名称")
        return true
    }

    private func runRound(manual: Bool = false) async -> TimeInterval {
        guard !refreshing, !switching, manual || (!manualRefreshPending && !verifying) else { return 120 }
        refreshing = true
        defer { refreshing = false; savePollState() }
        rotateLogIfNeeded()
        if AppSettings.shared.paused && !manual { return 60 }
        reloadConfig()
        slots = CredentialStore.load()
        var cooldown: TimeInterval = 0
        var attempted = 0
        var succeeded = 0
        var deferredUntil: [Date] = []
        let orderedAccounts = accounts.sorted { isActive($0) && !isActive($1) }
        for account in orderedAccounts {
            let now = Date()
            if let gate = quotaRefreshGate(manual: manual, nextEligible: nextEligible[account.id],
                                           lastAttempt: lastAttempts[account.id],
                                           lastResult: snapshots[account.id], now: now) {
                deferredUntil.append(gate)
                if manual { log("手动刷新等待：\(account.name)，剩余 \(Int(ceil(gate.timeIntervalSince(now))))s") }
                continue
            }
            attempted += 1
            lastAttempts[account.id] = now
            var slot = slots[CredentialStore.key(for: account)]
            if let existing = slot,
               expiresAt(of: existing.payload).map({ $0 < now.addingTimeInterval(300) }) ?? true {
                if let renewed = await refreshCredential(existing.payload) {
                    // 只有身份保持一致才保存续期结果。
                    if let token = accessToken(of: renewed),
                       let profile = await fetchProfile(token: token),
                       profile.account.email?.lowercased() == account.email?.lowercased(),
                       profile.organization?.uuid.lowercased() == account.org.lowercased() {
                        CredentialStore.store(payload: renewed, email: existing.email, for: account, refreshed: true)
                        if let live = KeychainCredentials.readLive(),
                           credentialFingerprint(live) == existing.fingerprint {
                            do { try KeychainCredentials.writeLive(renewed) }
                            catch { log("系统当前凭据续期同步失败") }
                        }
                        slots = CredentialStore.load()
                        slot = slots[CredentialStore.key(for: account)]
                        log("\(account.name) OAuth 已续期并核验身份")
                    }
                }
            }
            // cookie 可独立服务未配置 OAuth 的账号；不再读取 ClaudeBar 实时缓存。
            var result: Snapshot
            var verifiedPlan: String?
            if let slot, let token = accessToken(of: slot.payload) {
                if let profile = await fetchProfile(token: token),
                   profile.account.email?.lowercased() == account.email?.lowercased(),
                   profile.organization?.uuid.lowercased() == account.org.lowercased() {
                    result = await fetchOAuthUsage(token: token)
                    verifiedPlan = profile.planLabel(payload: slot.payload)
                } else {
                    result = Snapshot(fetchedAt: Date(), error: "无法核验 OAuth 身份，请重新登录")
                }
                if let error = result.error, !error.contains("429"), account.hasSession {
                    let fallback = await fetchUsage(account)
                    if fallback.error == nil || fallback.error?.contains("429") == true { result = fallback }
                    else if fallback.retryAfter != nil { result.retryAfter = fallback.retryAfter }
                }
            } else {
                result = await fetchUsage(account)
            }
            if result.error == nil {
                if verifiedPlan == nil, account.hasSession,
                   let identity = await fetchIdentity(sessionKey: account.sessionKey),
                   identity.email_address?.lowercased() == account.email?.lowercased(),
                   let org = identity.memberships?.first(where: { $0.organization.uuid.lowercased() == account.org.lowercased() })?.organization {
                    verifiedPlan = claudePlanLabel(subscription: org.subscription_type, tier: org.rate_limit_tier)
                        ?? org.capabilities?.compactMap { claudePlanLabel(subscription: $0, tier: org.rate_limit_tier) }.first
                }
                result.plan = verifiedPlan
            }
            snapshots[account.id] = result
            if let error = result.error {
                let n = min((consecutiveFailures[account.id] ?? 0) + 1, 10)
                consecutiveFailures[account.id] = n
                let backoff = max(result.retryAfter ?? 0, min(pow(2, Double(n)) * 60, 1800))
                nextEligible[account.id] = Date().addingTimeInterval(backoff)
                if error.contains("429") { cooldown = max(cooldown, backoff) }
                log("\(account.name) 独立取数失败：\(error)，保留历史数据，退避 \(Int(backoff))s")
            } else {
                succeeded += 1
                lastGood[account.id] = result
                Paths.saveSnapshots(lastGood)
                consecutiveFailures[account.id] = 0
                nextEligible[account.id] = Date().addingTimeInterval(900)
                evaluateThresholds(account: account, snapshot: result)
                let five = result.fiveHour?.utilization.map { Int($0) } ?? -1
                let seven = result.sevenDay?.utilization.map { Int($0) } ?? -1
                log("\(account.name) 独立取数成功 5h=\(five)% 7d=\(seven)% via \(result.source ?? "?")")
            }
            savePollState()
        }
        usingClaudeBarCache = false
        if attempted > 0 { lastRound = Date() }
        if manual {
            var messages: [String] = []
            if succeeded > 0 { messages.append("已更新\(succeeded)个账号") }
            let failed = attempted - succeeded
            if failed > 0 { messages.append("\(failed)个刷新失败，保留旧数据") }
            if let earliest = deferredUntil.min() {
                let seconds = max(1, Int(ceil(earliest.timeIntervalSinceNow)))
                let wait = seconds < 60 ? "\(seconds)秒" : "\(Int(ceil(Double(seconds) / 60)))分钟"
                messages.append("\(deferredUntil.count)个暂需等待，约\(wait)后可重试")
            }
            manualRefreshMessage = messages.isEmpty ? "还没有可刷新的账号" : messages.joined(separator: "；")
            log("手动刷新结果：\(manualRefreshMessage ?? "")")
        }
        TokenStats.shared.reload()
        if AppSettings.shared.keepAliveEnabled { await keepAliveIfNeeded() }
        return cooldown
    }

    /// 阈值提醒：跨过阈值时提醒一次，回落到阈值以下后重新武装。
    private func evaluateThresholds(account: Account, snapshot: Snapshot) {
        guard !diagnosticMode, AppSettings.shared.notifyEnabled else { return }
        let settings = AppSettings.shared
        check(window: "5h", account: account,
              value: snapshot.fiveHour?.utilization, threshold: settings.thresholdFive)
        check(window: "7d", account: account,
              value: snapshot.sevenDay?.utilization, threshold: settings.thresholdSeven)
    }

    private func check(window: String, account: Account, value: Double?, threshold: Int) {
        guard let value else { return }
        let key = "\(account.id)|\(window)"
        if value >= Double(threshold) {
            guard !crossed.contains(key) else { return }
            crossed.insert(key)
            Notifier.shared.post(key: "thr-\(key)",
                                 title: "\(account.name) \(window) 用到 \(Int(value))%",
                                 body: "已超过 \(threshold)% 的提醒线")
        } else if value < Double(threshold) - 5, crossed.contains(key) {
            crossed.remove(key)
        }
    }

    /// 网页登录态闲置超过 20 小时就轻量 ping 一次，避免过期。
    private func keepAliveIfNeeded() async {
        guard Date().timeIntervalSince(lastKeepAlive) > 6 * 3600 else { return }
        lastKeepAlive = Date()
        for account in accounts where account.hasSession {
            let idle = Date().timeIntervalSince(account.sessionSeenAt ?? .distantPast)
            guard idle > 20 * 3600 else { continue }
            let ok = await pingSession(sessionKey: account.sessionKey)
            if ok {
                Paths.touchSession(org: account.org)
                log("keep-alive 成功：\(account.name)")
            } else {
                log("keep-alive 失败：\(account.name)")
            }
        }
    }

    func diagnoseOneRound() async -> [[String: String]] {
        diagnosticMode = true
        defer { diagnosticMode = false }
        restorePollState()
        _ = await runRound(manual: true)
        return accounts.map { account in
            let shown = shownSnapshot(account)
            return ["name": account.name, "hasSession": String(account.hasSession),
                "hasOAuth": String(hasCredential(account)), "source": shown?.source ?? "none",
                "fetchedAt": shown.map { logFormatter.string(from: $0.fetchedAt) } ?? "none",
                "warning": dataWarning(account) ?? "none",
                "plan": shown?.plan ?? "unknown",
                "windows": shown?.quotaWindows.map { ($0.title.map { $0 + " " } ?? "") + $0.label }.joined(separator: ",") ?? ""]
        }
    }

    // MARK: 诊断

    func exportDiagnostics() -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/quotabar-diagnostics-\(stamp).log")
        var report = "QuotaBar \(appVersion) 诊断\n生成于 \(Date())\n\n"
        report += "账号：\(accounts.count) 个，凭据槽：\(slots.count) 个\n"
        report += "当前账号：\(activeAccount?.name ?? "未知")\n"
        report += "菜单栏：\(AppSettings.shared.menuBarStyle.rawValue)\n\n"
        for account in accounts {
            let snap = shownSnapshot(account)
            report += "- \(account.name) <\(account.email ?? "-")> org=\(account.org)\n"
            report += "  5h=\(snap?.fiveHour?.utilization.map { "\(Int($0))%" } ?? "-") "
            report += "7d=\(snap?.sevenDay?.utilization.map { "\(Int($0))%" } ?? "-") "
            report += "来源=\(snap?.source ?? "-") 错误=\(snap?.error ?? "无")\n"
        }
        report += "\n=== GPT 账号 ===\n"
        for store in CodexAccounts.shared.stores {
            let snap = store.snapshot
            report += "- \(snap?.email ?? "未识别账号") 套餐=\(snap?.plan ?? "未知")\n"
            report += "  额度=\(snap?.windows.map { "\($0.label)=\(Int($0.usedPercent))%" }.joined(separator: " ") ?? "无") 错误=\(store.error ?? "无")\n"
        }
        report += "\n=== 最近一次统一诊断 ===\n"
        if lastVerify == nil { report += "尚未运行\n" }
        for result in verifyResults {
            report += "\(result.name)：\(result.usageOK ? "通过" : "待处理") \(result.note)\n"
        }
        report += "\n=== quotabar.log 末尾 200 行 ===\n"
        if let text = try? String(contentsOf: logURL, encoding: .utf8) {
            report += text.split(separator: "\n").suffix(200).joined(separator: "\n")
        }
        do {
            try report.write(to: target, atomically: true, encoding: .utf8)
            return target
        } catch {
            log("导出诊断失败：\(error)")
            return nil
        }
    }
}

// 入口。

import AppKit
import SwiftUI

@main
enum QuotaBarEntry {
    @MainActor static func main() {
        CredentialAgent.installBundledIfMissing()
        if CommandLine.arguments.contains("--switch-readiness") {
            let slots = CredentialStore.load()
            let report = Paths.loadAccounts().map { account -> [String: Any] in
                let payload = slots[CredentialStore.key(for: account)]?.payload
                return ["name": account.name,
                        "hasOAuth": payload.flatMap(accessToken) != nil,
                        "expired": payload.flatMap { expiresAt(of: $0) }.map { $0 < Date() } ?? true,
                        "hasRefreshToken": payload.flatMap(oauthDictionary)?["refreshToken"] is String,
                        "hasWebSession": account.hasSession]
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        if CommandLine.arguments.contains("--update-check-once") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let updater = AppUpdater.shared
            updater.start()
            updater.probe { report in
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
                exit(report["feedVerified"] as? Bool == true ? 0 : 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(2) }
            NSApp.run()
            return
        }
        if CommandLine.arguments.contains("--diagnostics-once") {
            Task { @MainActor in
                let store = QuotaStore.shared
                await store.verifyAllNow()
                let report = store.verifyResults.map {
                    ["name": $0.name, "ok": $0.usageOK, "note": $0.note] as [String: Any]
                }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
                exit(0)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--claude-plan-evidence") {
            Task { @MainActor in
                let slots = CredentialStore.load()
                var reports: [[String: Any]] = []
                for account in Paths.loadAccounts() {
                    var report: [String: Any] = ["name": account.name]
                    let payload = slots[CredentialStore.key(for: account)]?.payload
                    let metadata = payload.flatMap(oauthDictionary) ?? [:]
                    report["savedMetadata"] = planEvidence(metadata)
                    if let token = payload.flatMap(accessToken), let url = URL(string: "https://api.anthropic.com/api/oauth/profile") {
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 8
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                        if let (data, _) = try? await oauthSession().data(for: request),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            report["profileKeys"] = object.keys.sorted()
                            report["profileMetadata"] = planEvidence(object)
                        }
                    }
                    if account.hasSession, let url = URL(string: "https://claude.ai/api/account") {
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 8
                        request.setValue("sessionKey=\(account.sessionKey)", forHTTPHeaderField: "Cookie")
                        if let (data, _) = try? await oauthSession().data(for: request),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            report["webKeys"] = object.keys.sorted()
                            report["webMetadata"] = planEvidence(object)
                        }
                    }
                    reports.append(report)
                }
                if let data = try? JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
                exit(0)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--codex-quota-check") {
            Task { @MainActor in
                await CodexQuotaStore.shared.refresh(manual: true)
                let store = CodexQuotaStore.shared
                let report: [String: Any] = ["email": store.snapshot?.email ?? "", "plan": store.snapshot?.plan ?? "",
                    "error": store.error ?? "", "message": store.message ?? "",
                    "windows": store.snapshot?.windows.map { ["label": $0.label, "usedPercent": $0.usedPercent,
                        "resetCountdown": resetCountdown($0.resetsAt, now: Date())] as [String: Any] } ?? []]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
                exit(store.error == nil && store.snapshot != nil ? 0 : 1)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--health-once") {
            Task { @MainActor in
                let report = await QuotaStore.shared.diagnoseOneRound()
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
                exit(0)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--sync-live-identity") {
            Task { @MainActor in
                guard let live = KeychainCredentials.readLive(), let token = accessToken(of: live),
                      let profile = await fetchProfile(token: token),
                      let account = Paths.loadAccounts().first(where: {
                          $0.email?.lowercased() == profile.account.email?.lowercased()
                          && $0.org.lowercased() == profile.organization?.uuid.lowercased()
                      }) else { print("Identity verification failed; unchanged"); exit(1) }
                do {
                    try ClaudeIdentityStore.synchronize(profile)
                    guard ClaudeIdentityStore.matches(account) else { print("Identity verification failed"); exit(1) }
                    print("Claude identity synchronized to \(account.name); shared token unchanged")
                    exit(0)
                } catch { print("Claude identity synchronization failed; backup retained"); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--active-account-check") {
            Task { @MainActor in
                let store = QuotaStore.shared
                await store.identifyActive()
                let keychainAccount = store.accounts.first { CredentialStore.key(for: $0) == store.activeKey }
                let report = ["name": store.activeAccount?.name ?? "未识别",
                              "keychainName": keychainAccount?.name ?? "未识别",
                              "identitySynchronized": String(keychainAccount.map { ClaudeIdentityStore.matches($0) } ?? false),
                              "source": store.activeIdentitySource,
                              "note": store.activeIdentityNote,
                              "menuBarText": store.menuBarText]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
                exit(0)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--repair-live-credential") {
            guard let old = CredentialAgent.call("live-read"), old.ok, let payload = old.value else {
                print("Repair unavailable; live credential unchanged"); exit(1)
            }
            let backupKey = "repair:live:" + UUID().uuidString
            do { try SecretVault.write(payload, key: backupKey) }
            catch { print("Backup failed; live credential unchanged"); exit(1) }
            guard SecretVault.read(key: backupKey) == payload else {
                print("Backup verification failed; live credential unchanged"); exit(1)
            }
            guard LiveCredentialBridge.call("migrate", value: payload)?.ok == true,
                  let live = KeychainCredentials.readLive(),
                  credentialFingerprint(live) == credentialFingerprint(payload) else {
                print("Repair incomplete; encrypted recovery copies retained"); exit(1)
            }
            print("Repair verified: same account and token, Apple-owned item, encrypted backup retained")
            return
        }
        if CommandLine.arguments.contains("--credential-check") {
            let reply = CredentialAgent.call("load")
            let live = LiveCredentialBridge.call("read")
            let report: [String: Any] = ["agentVerified": CredentialAgent.verified,
                "vaultAccessible": reply?.ok == true,
                "storedSecretCount": reply?.values?.count ?? 0,
                "liveReadable": live?.ok == true && live?.value != nil,
                "liveStatus": live?.status ?? -1]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        if CommandLine.arguments.contains("--recover-sessions") {
            guard let imported = AccountImport.read() else { print("Session recovery unavailable; unchanged"); return }
            let current = mergeImportedAccounts(Paths.loadAccounts(), imported)
            let saved = Paths.saveAccounts(current)
            print("Session recovery saved=\(saved) accounts=\(current.count) sessions=\(current.filter { $0.hasSession }.count)")
            return
        }
        QuotaBarApp.main()
    }
}

private func planEvidence(_ object: [String: Any], path: String = "", depth: Int = 0) -> [String: Any] {
    guard depth < 6 else { return [:] }
    let allowed: Set<String> = ["subscription_type", "subscriptionType", "rate_limit_tier", "rateLimitTier",
        "billing_type", "organization_type", "plan_type", "plan", "type", "capabilities", "has_claude_pro", "has_claude_max"]
    var result: [String: Any] = [:]
    for (key, value) in object {
        let name = path.isEmpty ? key : path + "." + key
        if allowed.contains(key), value is String || value is NSNumber || value is [String] { result[name] = value }
        if let nested = value as? [String: Any] { result.merge(planEvidence(nested, path: name, depth: depth + 1)) { a, _ in a } }
        if let array = value as? [[String: Any]] {
            for (index, item) in array.enumerated() {
                result.merge(planEvidence(item, path: name + "[\(index)]", depth: depth + 1)) { a, _ in a }
            }
        }
    }
    return result
}

struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = QuotaStore.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            Image(nsImage: QuotaBarLogo.menuBar)
                .accessibilityLabel("QuotaBar")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("launch pid=\(ProcessInfo.processInfo.processIdentifier) v\(appVersion)")
        Task { @MainActor in
            QuotaStore.shared.start()
            CodexAccounts.shared.start()
            AppUpdater.shared.start()
            if CommandLine.arguments.contains("--login-window") {
                LoginController.shared.present()
            }
            if CommandLine.arguments.contains("--settings") {
                openPanelWindow(showSettings: true)
            } else if CommandLine.arguments.contains("--panel-window") {
                openPanelWindow()
            }
        }
    }

    @MainActor
    private func openPanelWindow(showSettings: Bool = false) {
        let hosting = NSHostingView(rootView: ContentView(store: QuotaStore.shared, initialSettings: showSettings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: min(720, max(360, (NSScreen.main?.visibleFrame.height ?? 880) - 64))),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false  // owned by `panelWindow`; avoid a double release on close
        window.title = "QuotaBar 面板"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panelWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        CodexAccounts.shared.cancelLogin()
        log("terminate")
    }
}

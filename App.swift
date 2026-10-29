// 入口。

import AppKit
import SwiftUI

@main
enum QuotaBarEntry {
    @MainActor static func main() {
        CredentialAgent.installBundledIfMissing()
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
        if CommandLine.arguments.contains("--active-account-check") {
            Task { @MainActor in
                let store = QuotaStore.shared
                await store.identifyActive()
                let report = ["name": store.activeAccount?.name ?? "未识别",
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
        if CommandLine.arguments.contains("--credential-check") {
            let reply = CredentialAgent.call("load")
            let live = CredentialAgent.call("live-read")
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

import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    @Published private(set) var enabled = false
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyInstalls = false
    @Published private(set) var note = "更新服务尚未发布"
    private var controller: SPUStandardUpdaterController?
    private var probeCompletion: (([String: Any]) -> Void)?
    private var installation: Task<Void, Never>?

    func start() {
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "QuotaBarUpdatesEnabled") as? Bool == true,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/imchenhua/QuotaBar/"),
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyInstalls)
        do {
            try controller.updater.start()
            enabled = true
            note = "从 GitHub 获取签名更新"
        } catch {
            self.controller = nil
            note = "无法启用更新：" + error.localizedDescription
            log(note)
        }
    }

    func check() {
        guard let controller, canCheck else { return }
        note = "正在检查新版本…"
        controller.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ value: Bool) { controller?.updater.automaticallyChecksForUpdates = value }
    func setAutomaticInstallation(_ value: Bool) { controller?.updater.automaticallyDownloadsUpdates = value }

    /// Read-only release verification: uses Sparkle's feed validation without offering an install.
    func probe(_ completion: @escaping ([String: Any]) -> Void) {
        guard enabled, let controller else { completion(["enabled": false, "note": note]); return }
        probeCompletion = completion
        controller.updater.checkForUpdateInformation()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let completion = probeCompletion else { return }
        probeCompletion = nil
        let code = (error as NSError?)?.code ?? 0
        completion(["enabled": enabled, "canCheck": updater.canCheckForUpdates,
                    "automaticallyChecks": updater.automaticallyChecksForUpdates,
                    "automaticallyInstalls": updater.automaticallyDownloadsUpdates,
                    "feedVerified": code == 0 || code == 1001, "errorCode": code, "note": note])
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        note = "发现新版本 " + item.displayVersionString
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        note = code == 1001 ? "当前已是最新版本" : "更新检查未完成，请稍后重试"
    }

    // A menu-bar utility may never quit. Install silently once account operations are idle.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        note = "更新已下载，等待空闲时安装"
        installation?.cancel()
        installation = Task { @MainActor in
            while !Task.isCancelled {
                let store = QuotaStore.shared
                if !store.refreshBusy && !store.switching && !store.verifying &&
                   !LoginController.shared.isPresenting && !CodexAccounts.shared.signingIn &&
                   !CodexAccounts.shared.refreshing {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if Task.isCancelled { return }
                    // Recheck after the idle grace period.
                    if !store.refreshBusy && !store.switching && !store.verifying &&
                       !LoginController.shared.isPresenting && !CodexAccounts.shared.signingIn &&
                       !CodexAccounts.shared.refreshing {
                        immediateInstallHandler()
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return true
    }
}

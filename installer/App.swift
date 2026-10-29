import AppKit
import SwiftUI

@MainActor
final class InstallerModel: ObservableObject {
    @Published var installing = false
    @Published var complete = false
    @Published var message = "安装后可在菜单栏找到 QuotaBar 图标。"

    func install() {
        guard !installing, !complete else { return }
        installing = true
        message = "正在安装…"
        Task {
            defer { installing = false }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let destination = home.appendingPathComponent("Applications/QuotaBar.app")
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.rebon.quotabar")
            for application in running { application.terminate() }
            for _ in 0..<30 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !running.contains(where: { !$0.isTerminated }) else {
                message = "请先退出 QuotaBar，再点安装。"
                return
            }
            guard let source = Bundle.main.url(forResource: "QuotaBar", withExtension: "app") else {
                message = "安装包不完整，请重新下载。"
                return
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try InstallerFiles.install(source: source, destination: destination,
                        backupDirectory: home.appendingPathComponent(".local/share/quotabar-install-backups"))
                }.value
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
                complete = true
                message = "安装完成！点击菜单栏的 QuotaBar 图标查看额度。"
            } catch {
                message = "安装未完成，请重试。原账号资料保持不变。"
            }
        }
    }
}

struct InstallerView: View {
    @StateObject private var model = InstallerModel()
    var body: some View {
        VStack(spacing: 18) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon).resizable().frame(width: 88, height: 88)
            }
            Text("QuotaBar").font(.system(size: 28, weight: .semibold))
            Text(L("Claude 与 GPT 额度，一眼看清。"))
                .foregroundStyle(.secondary)
            Text(L(model.message)).font(.callout)
                .multilineTextAlignment(.center).frame(height: 45)
            if model.installing {
                ProgressView().controlSize(.small)
            } else if model.complete {
                Button(L("完成")) { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
            } else {
                Button(L("安装 QuotaBar")) { model.install() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36).frame(width: 430, height: 330)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#if !INSTALLER_TESTING
@main struct QuotaBarInstaller: App {
    var body: some Scene {
        Window(L("安装 QuotaBar"), id: "installer") { InstallerView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
    }
}
#endif

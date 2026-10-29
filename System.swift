// 切换账号后让 IDE 重新读取凭据。
//
// 用正常的 terminate + 重新打开：应用会走自己的退出流程，未保存的文档会拦住退出，
// 所以不会丢东西。默认关闭，��置里打开才生效。

import AppKit
import Foundation

enum IDERestart {
    private struct Target {
        let name: String
        let bundle: String
    }

    private static let targets: [Target] = [
        Target(name: "VS Code", bundle: "com.microsoft.VSCode"),
        Target(name: "Cursor", bundle: "com.todesktop.230313mzl4w4u92"),
        Target(name: "Windsurf", bundle: "com.exafunction.windsurf"),
        Target(name: "Zed", bundle: "dev.zed.Zed"),
        Target(name: "Xcode", bundle: "com.apple.dt.Xcode"),
    ]

    @MainActor
    static func runningClients() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundle = app.bundleIdentifier else { return nil }
            if bundle.hasPrefix("com.jetbrains.") { return app.localizedName ?? "JetBrains" }
            if let match = targets.first(where: { $0.bundle == bundle }) { return match.name }
            return nil
        }
    }

    /// 重新打开这些应用，让它们重新读 claude 的凭据。
    @MainActor
    static func restart() async -> [String] {
        var touched: [String] = []
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundle = app.bundleIdentifier else { return false }
            if bundle.hasPrefix("com.jetbrains.") { return true }
            return targets.contains { $0.bundle == bundle }
        }
        for app in apps {
            let url = app.bundleURL
            let name = app.localizedName ?? (url?.lastPathComponent ?? "应用")
            app.terminate()
            touched.append(name)
            // 等它自己退：未保存文档会拦住退出，那就这次不重开，交给用户。
            var waited = 0.0
            while !app.isTerminated && waited < 6 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 0.2
            }
            if app.isTerminated, let url {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                _ = try? await NSWorkspace.shared.openApplication(
                    at: url, configuration: config)
            } else {
                log("\(name) 没有在 6 秒内退出（可能有未保存的文档），跳过重开")
            }
        }
        if !touched.isEmpty { log("已重开 IDE：\(touched.joined(separator: "、"))") }
        return touched
    }
}

// MARK: - 电源状态

enum Power {
    /// 是否在用电池。macOS 没给纯净的 Swift API，读 pmset 是成本最低的做法。
    static func onBattery() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("Battery Power")
    }

    static func lowPowerMode() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

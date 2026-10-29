import AppKit
import Foundation

struct CodexQuotaWindow: Codable, Identifiable {
    let id: String
    let bucket: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
}

struct CodexQuotaSnapshot: Codable {
    let email: String
    let plan: String?
    let windows: [CodexQuotaWindow]
    let fetchedAt: Date
}

struct CodexAccount: Decodable, Equatable {
    let type: String
    let email: String?
    let planType: String?
    let id: String?
    let accountId: String?
}

struct CodexLimitsResponse: Decodable {
    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Double?
    }
    struct Bucket: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: Window?
        let secondary: Window?
        let planType: String?
    }
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?

    func snapshot(account: CodexAccount, now: Date) throws -> CodexQuotaSnapshot {
        guard account.type == "chatgpt", let email = account.email, !email.isEmpty else {
            throw CodexQuotaError.signedOut
        }
        let buckets: [(String, Bucket)]
        if let map = rateLimitsByLimitId, !map.isEmpty {
            buckets = map.sorted { lhs, rhs in
                if lhs.key == "codex" { return rhs.key != "codex" }
                if rhs.key == "codex" { return false }
                return lhs.key < rhs.key
            }
        } else if let rateLimits {
            buckets = [(rateLimits.limitId ?? "codex", rateLimits)]
        } else { throw CodexQuotaError.noWindows }
        var windows: [CodexQuotaWindow] = []
        for (key, bucket) in buckets {
            for (slot, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window else { continue }
                guard window.usedPercent.isFinite, window.usedPercent >= 0,
                      window.resetsAt.map({ $0.isFinite && $0 > 0 }) ?? true else {
                    throw CodexQuotaError.invalidResponse
                }
                let label: String
                if let mins = window.windowDurationMins, mins > 0 {
                    if mins % 1440 == 0 { label = "\(mins / 1440)天" }
                    else if mins % 60 == 0 { label = "\(mins / 60)小时" }
                    else { label = "\(mins)分" }
                } else { label = slot == "primary" ? "窗口1" : "窗口2" }
                windows.append(CodexQuotaWindow(id: key + ":" + slot,
                    bucket: bucket.limitName ?? (key == "codex" ? "Codex" : key), label: label,
                    usedPercent: window.usedPercent,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }))
            }
        }
        guard !windows.isEmpty else { throw CodexQuotaError.noWindows }
        return CodexQuotaSnapshot(email: email, plan: account.planType ?? rateLimits?.planType,
                                  windows: windows, fetchedAt: now)
    }
}

enum CodexQuotaError: Error {
    case cliMissing, signedOut, apiKey, timeout, rateLimited, invalidResponse, noWindows, identityChanged

    var message: String {
        switch self {
        case .cliMissing: return "未找到 Codex CLI"
        case .signedOut: return "请先在 Codex 中登录 ChatGPT 账号"
        case .apiKey: return "当前 Codex 使用 API Key，没有订阅额度窗口"
        case .timeout: return "Codex 额度查询超时"
        case .rateLimited: return "Codex 额度接口限流，请稍后重试"
        case .noWindows: return "当前账号未返回可显示的 Codex 额度窗口"
        case .identityChanged: return "查询期间 Codex 账号已变化，请重新刷新"
        case .invalidResponse: return "Codex 额度读取失败，请稍后重试"
        }
    }
}

/// Only three read-only RPC methods. No thread, turn, login, logout, or credit-reset requests.
enum CodexQuotaProbe {
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".local/bin/codex"),
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func read(executable: URL? = executable, timeout: TimeInterval = 40, home: URL? = nil) throws -> CodexQuotaSnapshot {
        guard let executable else { throw CodexQuotaError.cliMissing }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        if let home {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = home.path
            environment.removeValue(forKey: "OPENAI_API_KEY")
            environment.removeValue(forKey: "CODEX_API_KEY")
            process.environment = environment
        }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Do not forward protocol diagnostics or credential-related subprocess errors into app logs.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw CodexQuotaError.cliMissing }
        let watchdog = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // A CLI that ignores stdin closure or SIGTERM must not leave an orphan server.
            let end = Date().addingTimeInterval(1)
            while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            watchdog.cancel()
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value)
            try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
        }
        var buffer = Data()
        var received = 0
        func reply(_ id: Int) throws -> Data {
            while true {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          message["id"] as? Int == id else { continue }
                    if let error = message["error"] as? [String: Any] {
                        let text = (error["message"] as? String ?? "").lowercased()
                        if text.contains("429") || text.contains("too many requests") { throw CodexQuotaError.rateLimited }
                        throw CodexQuotaError.invalidResponse
                    }
                    guard let result = message["result"] else { throw CodexQuotaError.invalidResponse }
                    return try JSONSerialization.data(withJSONObject: result)
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw CodexQuotaError.timeout }
                received += chunk.count
                guard received <= 1_048_576 else { throw CodexQuotaError.invalidResponse }
                buffer.append(chunk)
            }
        }
        struct AccountReply: Decodable { let account: CodexAccount? }
        func account(_ id: Int) throws -> CodexAccount {
            try send(["id": id, "method": "account/read", "params": ["refreshToken": false]])
            let account = try JSONDecoder().decode(AccountReply.self, from: reply(id)).account
            guard let account else { throw CodexQuotaError.signedOut }
            guard account.type == "chatgpt" else { throw CodexQuotaError.apiKey }
            return account
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": [
            "name": "quotabar", "title": "QuotaBar", "version": appVersion]]])
        _ = try reply(1)
        try send(["method": "initialized", "params": [:]])
        let before = try account(2)
        try send(["id": 3, "method": "account/rateLimits/read"])
        let limits = try JSONDecoder().decode(CodexLimitsResponse.self, from: reply(3))
        let after = try account(4)
        guard before == after else { throw CodexQuotaError.identityChanged }
        return try limits.snapshot(account: after, now: Date())
    }
}

@MainActor
final class CodexQuotaStore: ObservableObject, Identifiable {
    static let shared = CodexQuotaStore()
    static let preview = CodexQuotaStore(preview: true)
    @Published private(set) var snapshot: CodexQuotaSnapshot?
    @Published private(set) var refreshing = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    private var lastAttempt: Date?
    private var nextEligible: Date?
    private var rateLimitedUntil: Date?
    private var failures = 0
    private var loop: Task<Void, Never>?
    private let cacheURL: URL
    private let isPreview: Bool
    let id: String
    let home: URL?
    private struct Cache: Codable {
        var snapshot: CodexQuotaSnapshot?
        var lastAttempt: Date?
        var nextEligible: Date?
        var rateLimitedUntil: Date?
        var error: String?
    }

    init(preview: Bool = false, id: String = "current", home: URL? = nil) {
        self.id = id
        self.home = home
        isPreview = preview
        cacheURL = home?.appendingPathComponent("quotabar-quota.json") ?? Paths.configDir.appendingPathComponent("codex-quota.json")
        if preview {
            snapshot = CodexQuotaSnapshot(email: "you@example.com", plan: "prolite", windows: [
                CodexQuotaWindow(id: "codex:primary", bucket: "Codex", label: "7天", usedPercent: 53,
                                 resetsAt: Date().addingTimeInterval(3 * 86400 + 6 * 3600))], fetchedAt: Date())
        } else if let data = try? Data(contentsOf: cacheURL),
                  let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            snapshot = cache.snapshot
            lastAttempt = cache.lastAttempt
            nextEligible = cache.nextEligible
            rateLimitedUntil = cache.rateLimitedUntil
            error = cache.error
        }
    }

    func start() {
        guard loop == nil, !isPreview else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func refreshNow() {
        guard !refreshing else { return }
        Task { await refresh(manual: true) }
    }

    func stop() { loop?.cancel(); loop = nil }

    func refresh(manual: Bool = false) async {
        guard !refreshing, !isPreview else { return }
        let now = Date()
        if !manual && AppSettings.shared.paused { return }
        let gate = manual ? max(rateLimitedUntil ?? .distantPast,
                               lastAttempt?.addingTimeInterval(10) ?? .distantPast)
                          : nextEligible ?? .distantPast
        if gate > now {
            if manual {
                let seconds = max(1, Int(ceil(gate.timeIntervalSince(now))))
                message = "约\(seconds < 60 ? "\(seconds)秒" : "\(Int(ceil(Double(seconds) / 60)))分钟")后可重试"
            }
            return
        }
        refreshing = true
        lastAttempt = now
        message = "正在刷新 GPT 额度…"
        defer { refreshing = false; save() }
        do {
            let home = self.home
            let value = try await Task.detached(priority: .utility) { try CodexQuotaProbe.read(home: home) }.value
            snapshot = value
            error = nil
            failures = 0
            rateLimitedUntil = nil
            let interval: TimeInterval = AppSettings.shared.adaptiveRefresh &&
                (Power.onBattery() || Power.lowPowerMode()) ? 900 : 300
            nextEligible = Date().addingTimeInterval(interval)
            message = manual ? "GPT 额度已更新" : nil
            log("Codex 额度取数成功：\(value.windows.map { "\($0.label)=\(Int($0.usedPercent))%" }.joined(separator: " "))")
        } catch {
            let failure = error as? CodexQuotaError ?? .invalidResponse
            self.error = failure.message
            failures = min(failures + 1, 5)
            let seconds = min(pow(2, Double(failures)) * 60, 1800)
            nextEligible = Date().addingTimeInterval(seconds)
            if case .rateLimited = failure { rateLimitedUntil = nextEligible }
            if case .signedOut = failure { snapshot = nil }
            if case .apiKey = failure { snapshot = nil }
            if case .identityChanged = failure { snapshot = nil }
            message = nil
            log("Codex 额度取数失败：\(failure.message)")
        }
    }

    private func save() {
        let cache = Cache(snapshot: snapshot, lastAttempt: lastAttempt, nextEligible: nextEligible,
                          rateLimitedUntil: rateLimitedUntil, error: error)
        if let data = try? JSONEncoder().encode(cache) { try? privateWrite(data, to: cacheURL) }
    }
}

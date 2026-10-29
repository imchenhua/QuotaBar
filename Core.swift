// QuotaBar 核心层：日志、数据模型、配置存储、钥匙串。
//
// 与 ClaudeBar 的关键差别（都是为了不再卡死）：
//   1. 全程没有任何后台 WebView。登录窗口只在用户点「登录」时存在，关掉即销毁。
//   2. 每个请求都有硬超时；一轮结束后必 sleep，循环结构上不可能空转。
//   3. 每个账号单独退避：连续失败就指数拉长间隔，封顶 30 分钟。
//   4. 不装信号处理器，也就没有「信号处理器里再触发信号」那种死递归。

import AppKit
import CryptoKit
import Foundation

let appVersion = "2.5.0"

// MARK: - 日志

let logURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/QuotaBar", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("quotabar.log")
}()
let logDirectory: URL = logURL.deletingLastPathComponent()

let logFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func log(_ message: String) {
    let line = "\(logFormatter.string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

/// 日志超过 1 MB 就滚动一次，免得无限长。
func rotateLogIfNeeded() {
    let fm = FileManager.default
    guard let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int,
          size > 1_048_576
    else { return }
    let old = logDirectory.appendingPathComponent("quotabar.1.log")
    try? fm.removeItem(at: old)
    try? fm.moveItem(at: logURL, to: old)
}

// MARK: - 数据模型

struct Account: Codable, Identifiable {
    var name: String
    var email: String?
    var org: String
    var sessionKey: String
    var id: String { org }

    var hasSession: Bool { !sessionKey.isEmpty }

    /// cookie 最后一次确认可用的时间，用于 keep-alive 判断。
    var sessionSeenAt: Date?

    var initial: String { String(name.prefix(1)).uppercased() }
}

func mergeImportedAccounts(_ current: [Account], _ imported: [Account]) -> [Account] {
    var result = current
    for account in imported {
        if let index = result.firstIndex(where: { $0.org.lowercased() == account.org.lowercased() }) {
            if !account.sessionKey.isEmpty { result[index].sessionKey = account.sessionKey }
            if result[index].email == nil { result[index].email = account.email }
        } else { result.append(account) }
    }
    return result
}

/// Identity only: this command never runs inference and its raw output is never logged.
struct CLIAuthStatus: Decodable {
    let loggedIn: Bool
    let authMethod: String?
    let email: String?
    let orgId: String?
}

func accountMatchingCLIStatus(_ status: CLIAuthStatus, accounts: [Account]) -> Account? {
    guard status.loggedIn, status.authMethod == "claude.ai",
          let email = status.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          let org = status.orgId?.lowercased(), !email.isEmpty, !org.isEmpty else { return nil }
    return accounts.first { $0.email?.lowercased() == email && $0.org.lowercased() == org }
}

enum ClaudeCLIIdentity {
    static func status() -> CLIAuthStatus? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/claude").path,
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["auth", "status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // A signed-out CLI may return a nonzero exit code with valid identity status.
        guard data.count < 1_048_576 else { return nil }
        return try? JSONDecoder().decode(CLIAuthStatus.self, from: data)
    }
}

struct UsageWindow: Codable {
    var utilization: Double?
    var resetsAt: Date?
}

func resetCountdown(_ reset: Date?, now: Date) -> String {
    guard let reset else { return "—" }
    let remaining = reset.timeIntervalSince(now)
    guard remaining > 0 else { return "待刷新" }
    guard remaining >= 60 else { return "<1m" }
    let minutes = Int(ceil(remaining / 60))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    let mins = minutes % 60
    var parts: [String] = []
    if days > 0 { parts.append("\(days)d") }
    if hours > 0 { parts.append("\(hours)h") }
    if mins > 0 { parts.append("\(mins)m") }
    return parts.joined()
}

struct Snapshot: Codable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var fetchedAt: Date
    var error: String?
    /// 服务端明确要求等多久（429 的 Retry-After），有就按它来。
    var retryAfter: TimeInterval? = nil
    /// 这份数据是哪个途径拿到的：oauth / cookie / 无。
    var source: String? = nil
    var plan: String? = nil
    var additionalWindows: [ClaudeQuotaWindow]? = nil

    var quotaWindows: [ClaudeQuotaWindow] {
        var result: [ClaudeQuotaWindow] = []
        if let fiveHour, fiveHour.utilization != nil {
            result.append(ClaudeQuotaWindow(id: "five_hour", title: nil, label: "5h", window: fiveHour))
        }
        if let sevenDay, sevenDay.utilization != nil {
            result.append(ClaudeQuotaWindow(id: "seven_day", title: nil, label: "7d", window: sevenDay))
        }
        return result + (additionalWindows ?? []).filter { $0.window.utilization != nil }
    }
}

struct ClaudeQuotaWindow: Codable, Identifiable {
    var id: String
    var title: String?
    var label: String
    var window: UsageWindow
}

func claudePlanLabel(subscription: String?, tier: String?) -> String? {
    let names = ["free": "Free", "pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise", "ultra": "Ultra"]
    let subscription = subscription?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        .replacingOccurrences(of: "claude_", with: "")
    let words = (tier ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    let key = subscription.flatMap { names[$0] == nil ? nil : $0 } ?? words.first { names[$0] != nil }
    guard let key, let name = names[key] else { return nil }
    if key == "max", let index = words.firstIndex(of: "max"), words.indices.contains(index + 1),
       ["5x", "20x"].contains(words[index + 1]) { return name + " " + words[index + 1] }
    return name
}

/// Manual refresh bypasses the regular poll interval, but never a rate limit or rapid repeat.
func quotaRefreshGate(manual: Bool, nextEligible: Date?, lastAttempt: Date?,
                      lastResult: Snapshot?, now: Date) -> Date? {
    let futureGate = nextEligible.flatMap { $0 > now ? $0 : nil }
    guard manual else { return futureGate }
    if lastResult?.error?.contains("429") == true || lastResult?.retryAfter != nil {
        if let futureGate { return futureGate }
    }
    if let lastAttempt, lastAttempt.addingTimeInterval(10) > now {
        return lastAttempt.addingTimeInterval(10)
    }
    return nil
}

struct AccountsFile: Codable {
    var accounts: [Account]
}

enum Paths {
    static var configDir: URL {
        if let path = ProcessInfo.processInfo.environment["QUOTABAR_PROFILE_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quotabar", isDirectory: true)
    }
    static var accountsFile: URL { configDir.appendingPathComponent("accounts.json") }
    static var snapshotFile: URL { configDir.appendingPathComponent("last-good.json") }

    static func loadSnapshots() -> [String: Snapshot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: snapshotFile),
              let result = try? decoder.decode([String: Snapshot].self, from: data)
        else { return [:] }
        return result
    }

    static func saveSnapshots(_ snapshots: [String: Snapshot]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do { try privateWrite(encoder.encode(snapshots), to: snapshotFile) }
        catch { log("保存额度缓存失败") }
    }

    static func loadAccounts() -> [Account] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: accountsFile),
              let file = try? decoder.decode(AccountsFile.self, from: data)
        else { return [] }
        var accounts = file.accounts
        var migrated = false
        for i in accounts.indices {
            let key = "session:" + accounts[i].org.lowercased()
            if !accounts[i].sessionKey.isEmpty {
                do {
                    try SecretVault.write(accounts[i].sessionKey, key: key)
                    migrated = true
                } catch { log("网页登录态迁移失败，保留原文件"); return accounts }
            } else {
                accounts[i].sessionKey = SecretVault.read(key: key) ?? ""
            }
        }
        if migrated { saveAccounts(accounts) }
        return accounts
    }

    @discardableResult
    static func saveAccounts(_ accounts: [Account]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            var metadata = accounts
            for i in metadata.indices {
                if !metadata[i].sessionKey.isEmpty {
                    try SecretVault.write(metadata[i].sessionKey,
                                          key: "session:" + metadata[i].org.lowercased())
                }
                metadata[i].sessionKey = ""
            }
            try privateWrite(encoder.encode(AccountsFile(accounts: metadata)), to: accountsFile)
            return true
        } catch { log("保存账号失败，原配置保留"); return false }
    }

    @discardableResult
    static func upsert(_ account: Account) -> Bool {
        var current = loadAccounts()
        if let index = current.firstIndex(where: { $0.org.lowercased() == account.org.lowercased() }) {
            // 保留已有的 sessionSeenAt，别被覆盖成 nil。
            var merged = account
            if merged.sessionSeenAt == nil { merged.sessionSeenAt = current[index].sessionSeenAt }
            current[index] = merged
        } else {
            current.append(account)
        }
        return saveAccounts(current)
    }

    static func touchSession(org: String) {
        var current = loadAccounts()
        guard let index = current.firstIndex(where: { $0.org == org }) else { return }
        current[index].sessionSeenAt = Date()
        saveAccounts(current)
    }

    static func remove(org: String) -> Bool {
        guard saveAccounts(loadAccounts().filter { $0.org != org }) else { return false }
        SecretVault.remove(key: "session:" + org.lowercased())
        return true
    }
}

// MARK: - 凭据槽
//
// ClaudeBar 只留「当前」和「上一份」两个凭据位，第三个账号每次都要重走一遍网页
// 登录——那正是它卡死的路。这里每个账号各存一份 OAuth 凭据，切换就是把存好的
// 那份写回系统钥匙串：不联网、不弹窗、不重试，也就没有空转的可能。

struct CredentialSlot: Codable {
    var email: String
    var payload: String
    var fingerprint: String
    var savedAt: Date
    var refreshedAt: Date?
}

enum CredentialError: Error, CustomStringConvertible {
    case cli(String)

    var description: String {
        switch self {
        case .cli(let message): return message
        }
    }
}

func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func oauthDictionary(_ payload: String) -> [String: Any]? {
    guard let data = payload.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any]
    else { return nil }
    return oauth
}

func credentialFingerprint(_ payload: String) -> String? {
    guard let token = oauthDictionary(payload)?["accessToken"] as? String, !token.isEmpty else {
        return nil
    }
    return sha256Hex(token)
}

enum CredentialStore {
    static var file: URL { Paths.configDir.appendingPathComponent("credentials.json") }
    static var backupDir: URL { Paths.configDir.appendingPathComponent("backups", isDirectory: true) }

    static func key(for account: Account) -> String {
        if let email = account.email?.lowercased(), !email.isEmpty { return email }
        return "org:" + account.org
    }

    static func load() -> [String: CredentialSlot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file),
              var slots = try? decoder.decode([String: CredentialSlot].self, from: data)
        else { return [:] }
        var migrated = false
        for key in Array(slots.keys) {
            if let payload = slots[key]?.payload, !payload.isEmpty {
                do { try SecretVault.write(payload, key: "oauth:" + key); migrated = true }
                catch { log("OAuth 迁移失败，保留原文件"); return slots }
            } else if let payload = SecretVault.read(key: "oauth:" + key) {
                slots[key]?.payload = payload
            } else {
                // 钥匙串暂时锁定或拒绝访问时保留元数据，避免误删账号凭据。
                // 保留空载荷元数据；界面会显示需要登录，后台不申请系统授权。
            }
        }
        if migrated { save(slots) }
        return slots
    }

    @discardableResult
    static func save(_ slots: [String: CredentialSlot]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            var metadata = slots
            for (key, slot) in slots {
                if !slot.payload.isEmpty { try SecretVault.write(slot.payload, key: "oauth:" + key) }
                metadata[key]?.payload = ""
            }
            try privateWrite(encoder.encode(metadata), to: file)
            return true
        } catch { log("保存 OAuth 凭据失败，原配置保留"); return false }
    }

    @discardableResult
    static func store(payload: String, email: String, for account: Account, refreshed: Bool = false) -> Bool {
        guard let fingerprint = credentialFingerprint(payload) else { return false }
        var slots = load()
        let key = key(for: account)
        let previous = slots[key]
        slots[key] = CredentialSlot(
            email: email,
            payload: payload,
            fingerprint: fingerprint,
            savedAt: previous?.savedAt ?? Date(),
            refreshedAt: refreshed ? Date() : previous?.refreshedAt)
        return save(slots)
    }

    /// 回滚副本只放钥匙串，不再生成含 token 的明文备份。
    static func backupLive(_ payload: String) {
        do { try SecretVault.write(payload, key: "rollback:live") }
        catch { log("无法保存钥匙串回滚副本") }
    }

    static func latestBackup() -> String? { SecretVault.read(key: "rollback:live") }

    static func migrateLegacyBackups() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: backupDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let payload = try? String(contentsOf: file, encoding: .utf8),
                  credentialFingerprint(payload) != nil else { continue }
            do {
                try SecretVault.write(payload, key: "legacy-backup:" + file.lastPathComponent)
                // 保留备份文件及其身份，凭据迁移成功后再替换为引用。
                let marker = try JSONSerialization.data(withJSONObject:
                    ["keychainReference": "legacy-backup:" + file.lastPathComponent])
                try privateWrite(marker, to: file)
            } catch { log("旧备份迁移失败，原文件保留") }
        }
    }
}

func privateWrite(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    // 目录只允许当前用户访问，原子写入后固定文件权限。
    try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                          ofItemAtPath: url.deletingLastPathComponent().path)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

// The GUI never accesses Keychain or launches the system `security` tool.
// CredentialAgent is a separate, pinned binary retained across GUI updates.
struct AgentReply: Decodable {
    let ok: Bool
    let values: [String: String]?
    let value: String?
    let status: Int32?
    let error: String?
}

enum CredentialAgent {
    /// Fresh installs copy the reviewed identity once. Existing identities are never replaced by app updates.
    static func installBundledIfMissing() {
        guard !FileManager.default.fileExists(atPath: executable.path),
              Bundle.main.bundleURL.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/QuotaBar.app").standardizedFileURL.path,
              let bundled = Bundle.main.url(forResource: "credential-agent-v1", withExtension: nil),
              let data = try? Data(contentsOf: bundled),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == credentialAgentSHA256 else { return }
        let directory = executable.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("credential-agent-v1-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: executable)
            if let manifest = Bundle.main.url(forResource: "credential-agent-v1", withExtension: "json") {
                try? FileManager.default.copyItem(at: manifest, to: executable.appendingPathExtension("json"))
            }
        } catch { try? FileManager.default.removeItem(at: temporary) }
    }
    static var executable: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/libexec/quotabar/credential-agent-v1")
    }
    static var verified: Bool {
        guard let data = try? Data(contentsOf: executable) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == credentialAgentSHA256
    }
    static func call(_ operation: String, values: [String: String]? = nil,
                     key: String? = nil, value: String? = nil) -> AgentReply? {
        guard verified else { return nil }
        let process = Process()
        process.executableURL = executable
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var request: [String: Any] = ["operation": operation]
        if let values { request["values"] = values }
        if let key { request["key"] = key }
        if let value { request["value"] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        do {
            try process.run()
            // Interactive access is reachable only through the user's Switch action.
            DispatchQueue.global().asyncAfter(deadline: .now() + (operation == "switch" ? 120 : 8)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
        } catch { if process.isRunning { process.terminate() }; return nil }
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try? JSONDecoder().decode(AgentReply.self, from: response)
    }
}

enum SecretVault {
    static func read(key: String) -> String? {
        if let reply = CredentialAgent.call("load"), reply.ok,
           let value = reply.values?[key] { return value }
        // Best-effort recovery is noninteractive and never changes the old vault.
        if let legacy = CredentialAgent.call("legacy-read", key: key), legacy.ok,
           let value = legacy.value {
            try? write(value, key: key)
            return value
        }
        return nil
    }
    static func write(_ value: String, key: String) throws {
        guard let result = CredentialAgent.call("put", values: [key: value]), result.ok else {
            throw CredentialError.cli("凭据未保存：组件不可用或钥匙串暂不可访问；原资料保留")
        }
    }
    static func remove(key: String) { _ = CredentialAgent.call("remove", key: key) }
}

enum KeychainCredentials {
    static func readLive() -> String? {
        let reply = CredentialAgent.call("live-read")
        return reply?.ok == true ? reply?.value : nil
    }
    /// Silent synchronization only. No prompts and no live account changes without a matching read.
    static func writeLive(_ payload: String) throws {
        guard CredentialAgent.call("live-write", value: payload)?.ok == true else {
            throw CredentialError.cli("当前 Claude Code 凭据受系统保护，未修改")
        }
    }
    /// Explicit user action; stable agent owns any resulting authorization.
    static func switchLive(_ payload: String) throws {
        guard let reply = CredentialAgent.call("switch", value: payload), reply.ok else {
            throw CredentialError.cli("切换未完成：系统授权被拒绝或凭据不可用，请检查当前登录状态")
        }
    }
}

enum AccountImport {
    static func read() -> [Account]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin/quotabar-import.py").path, "--export"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (try? JSONDecoder().decode(AccountsFile.self, from: data))?.accounts
    }
}

// MARK: - 时间解析

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoFormatterNoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    return isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
}

func accessToken(of payload: String) -> String? {
    oauthDictionary(payload)?["accessToken"] as? String
}

func expiresAt(of payload: String) -> Date? {
    guard let ms = oauthDictionary(payload)?["expiresAt"] as? Double else { return nil }
    return Date(timeIntervalSince1970: ms / 1000)
}

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

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"

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

enum ClaudeIdentityStore {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }
    static func matches(_ account: Account, at url: URL = defaultURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identity = root["oauthAccount"] as? [String: Any],
              let email = identity["emailAddress"] as? String,
              let org = identity["organizationUuid"] as? String else { return false }
        return email.lowercased() == account.email?.lowercased() && org.lowercased() == account.org.lowercased()
    }
    static func read(at url: URL = defaultURL) throws -> [String: Any]? {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.cli("Claude 配置格式错误，原文件保留")
        }
        return root["oauthAccount"] as? [String: Any]
    }
    /// Replace only the account identity, retaining unrelated Claude settings and a private backup.
    static func synchronize(_ profile: OAuthProfile, at url: URL = defaultURL,
                            backupDirectory: URL? = nil) throws {
        guard let uuid = profile.account.uuid, !uuid.isEmpty,
              let email = profile.account.email, !email.isEmpty,
              let org = profile.organization?.uuid, !org.isEmpty else {
            throw CredentialError.cli("账号身份资料不完整，未修改 Claude 配置")
        }
        var identity: [String: Any] = ["accountUuid": uuid, "emailAddress": email, "organizationUuid": org]
        if let name = profile.account.full_name { identity["displayName"] = name; identity["fullName"] = name }
        if let billing = profile.organization?.billing_type { identity["billingType"] = billing }
        if let type = profile.organization?.organization_type { identity["organizationType"] = type }
        if let tier = profile.organization?.rate_limit_tier { identity["organizationRateLimitTier"] = tier }
        try write(identity, at: url, backupDirectory: backupDirectory)
    }
    static func write(_ identity: [String: Any]?, at url: URL = defaultURL,
                      backupDirectory: URL? = nil) throws {
        let fm = FileManager.default
        let backup = backupDirectory ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/quotabar/identity-backups")
        for attempt in 0..<3 {
            let original = try Data(contentsOf: url)
            guard var root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw CredentialError.cli("Claude 配置格式错误，原文件保留")
            }
            root["oauthAccount"] = identity
            let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let copy = backup.appendingPathComponent(UUID().uuidString + ".json")
            guard fm.createFile(atPath: copy.path, contents: original, attributes: [.posixPermissions: 0o600]) else {
                throw CredentialError.cli("Claude 身份备份失败，未修改")
            }
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".quotabar-identity-" + UUID().uuidString)
            guard fm.createFile(atPath: temporary.path, contents: updated, attributes: [.posixPermissions: 0o600]) else {
                throw CredentialError.cli("Claude 身份写入准备失败，原文件保留")
            }
            defer { try? fm.removeItem(at: temporary) }
            guard try Data(contentsOf: url) == original else {
                if attempt < 2 { continue }
                throw CredentialError.cli("Claude 配置正在变化，请稍后重试")
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw CredentialError.cli("Claude 身份文件未能替换，原文件保留")
            }
            return
        }
    }
}

enum ClaudeAccountSwitch {
    /// Commit both shared stores together; never report a token-only update as success.
    static func commit(payload: String, profile: OAuthProfile, account: Account,
                       identityURL: URL = ClaudeIdentityStore.defaultURL, backupDirectory: URL? = nil,
                       read: () -> String? = { KeychainCredentials.readLive() },
                       write: (String) throws -> Void = { try KeychainCredentials.switchLive($0) }) throws {
        if identityURL == ClaudeIdentityStore.defaultURL && claudeRefreshInProgress() {
            throw CredentialError.cli("Claude Code 正在续期，请稍后重试切换")
        }
        guard let expectedUUID = profile.account.uuid, !expectedUUID.isEmpty,
              let expectedEmail = profile.account.email, !expectedEmail.isEmpty,
              expectedEmail.lowercased() == account.email?.lowercased(),
              profile.organization?.uuid.lowercased() == account.org.lowercased(),
              credentialFingerprint(payload) != nil, let original = read(), credentialFingerprint(original) != nil else {
            throw CredentialError.cli("切换前身份或凭据验证失败，未修改")
        }
        let previousIdentity = try ClaudeIdentityStore.read(at: identityURL)
        var attemptedToken = false, wroteIdentity = false
        do {
            attemptedToken = true; try write(payload)
            try ClaudeIdentityStore.synchronize(profile, at: identityURL, backupDirectory: backupDirectory)
            wroteIdentity = true
            guard let result = read(), credentialFingerprint(result) == credentialFingerprint(payload),
                  ClaudeIdentityStore.matches(account, at: identityURL),
                  try ClaudeIdentityStore.read(at: identityURL)?["accountUuid"] as? String == expectedUUID else {
                throw CredentialError.cli("切换后身份与凭据不一致")
            }
        } catch {
            do {
                if attemptedToken && read().flatMap(credentialFingerprint) != credentialFingerprint(original) {
                    try write(original)
                    guard read().flatMap(credentialFingerprint) == credentialFingerprint(original) else {
                        throw CredentialError.cli("回滚后凭据仍不一致")
                    }
                }
                if wroteIdentity { try ClaudeIdentityStore.write(previousIdentity, at: identityURL, backupDirectory: backupDirectory) }
            } catch { throw CredentialError.cli("切换失败，未能完整恢复原账号，请运行统一诊断") }
            throw CredentialError.cli("切换未完成，已保留或恢复原账号")
        }
    }
}

func claudeRefreshInProgress(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"), now: Date = Date()) -> Bool {
    let lock = directory.appendingPathComponent(".oauth_refresh.lock")
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: lock.path),
          let modified = attributes[.modificationDate] as? Date else { return false }
    return now.timeIntervalSince(modified) < 60
}

func canRefreshPrivateCredential(_ payload: String, accountKey: String,
                                 livePayload: String?, liveAccountKey: String?) -> Bool {
    guard let livePayload else { return false } // Unreadable is not proof that no shared login exists.
    guard let liveAccountKey else { return false } // Unknown shared owner: avoid rotating any possibly shared login.
    if liveAccountKey == accountKey { return false }
    if credentialFingerprint(payload) == credentialFingerprint(livePayload) { return false }
    if let refresh = oauthDictionary(payload)?["refreshToken"] as? String, !refresh.isEmpty,
       refresh == oauthDictionary(livePayload)?["refreshToken"] as? String { return false }
    return true
}

final class OAuthRefreshLease {
    private let url: URL
    private init(_ url: URL) { self.url = url }
    static func acquire(_ key: String, directory: URL = Paths.configDir.appendingPathComponent("refresh-locks")) -> OAuthRefreshLease? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(sha256Hex(key))
            if let attributes = try? fm.attributesOfItem(atPath: url.path),
               let modified = attributes[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > 90 { try? fm.removeItem(at: url) }
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return OAuthRefreshLease(url)
        } catch { return nil }
    }
    deinit { try? FileManager.default.removeItem(at: url) }
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

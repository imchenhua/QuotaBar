// QuotaBar 凭据层：每账号凭据槽、钥匙串、固定身份凭据助手、私有保险库与账号导入。
// 从 Core.swift 拆出；与 Core.swift 同属一个模块，所有编译命令需同时包含两者。

import AppKit
import CryptoKit
import Foundation

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
        // v1 remains immutable and owns only QuotaBar's private vault. Its native
        // live writes reset partition ACLs and must never be reachable again.
        guard operation != "live-write", operation != "switch" else { return nil }
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

enum LiveCredentialBridge {
    static func call(_ operation: String, value: String? = nil) -> AgentReply? {
        guard let url = Bundle.main.url(forResource: "live-credential-bridge", withExtension: nil),
              let data = try? Data(contentsOf: url),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == liveCredentialBridgeSHA256 else { return nil }
        let p = Process(); p.executableURL = url
        let input = Pipe(), output = Pipe(); p.standardInput = input; p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        var request: [String: Any] = ["operation": operation]; request["value"] = value
        guard let requestData = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        do {
            try p.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 25) { if p.isRunning { p.terminate() } }
            try input.fileHandleForWriting.write(contentsOf: requestData); try input.fileHandleForWriting.close()
        } catch { if p.isRunning { p.terminate() }; return nil }
        let response = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return try? JSONDecoder().decode(AgentReply.self, from: response)
    }
}

enum KeychainCredentials {
    static func readLive() -> String? {
        let reply = LiveCredentialBridge.call("read")
        return reply?.ok == true ? reply?.value : nil
    }
    /// Both refresh and switching use Apple-owned writes, with no authorization fallback.
    static func switchLive(_ payload: String,
                           perform: (String, String) -> AgentReply? = { LiveCredentialBridge.call($0, value: $1) }) throws {
        guard let reply = perform("write", payload), reply.ok else {
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

// Stable credential agent. Keep this binary unchanged across UI-only updates.
import Foundation
import Security
import CryptoKit
import Darwin

struct Request: Decodable {
    let operation: String
    let values: [String: String]?
    let key: String?
    let value: String?
}
struct Reply: Encodable {
    let ok: Bool
    let values: [String: String]?
    let value: String?
    let status: Int32
    let error: String?
    init(ok: Bool, values: [String: String]? = nil, value: String? = nil,
         status: Int32 = 0, error: String? = nil) {
        self.ok = ok; self.values = values; self.value = value
        self.status = status; self.error = error
    }
}
struct VaultError: Error { let status: OSStatus }

#if VAULT_TESTING
let vaultService = "dev.rebon.quotabar.agent.tests"
let liveService = "dev.rebon.quotabar.agent.tests.live"
let expectedParent = ProcessInfo.processInfo.environment["QUOTABAR_TEST_PARENT"] ?? ""
let expectedIdentifier = "dev.rebon.quotabar.tests"
let lockURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUOTABAR_TEST_LOCK"] ?? "/nonexistent")
#else
let vaultService = "dev.rebon.quotabar.agent.v1"
let liveService = "Claude Code-credentials"
let expectedParent = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Applications/QuotaBar.app/Contents/MacOS/QuotaBar").path
let expectedIdentifier = "dev.rebon.quotabar"
let lockURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/quotabar/credential-agent.lock")
#endif

func callerIsTrusted() -> Bool {
    let pid = getppid()
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
    let actual = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
    guard !expectedParent.isEmpty,
          actual == URL(fileURLWithPath: expectedParent).resolvingSymlinksInPath().path else { return false }
    var dynamicCode: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil,
        [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary,
        SecCSFlags(), &dynamicCode) == errSecSuccess, let dynamicCode else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(("identifier \"" + expectedIdentifier + "\"") as CFString,
        SecCSFlags(), &requirement) == errSecSuccess,
        SecCodeCheckValidity(dynamicCode, SecCSFlags(), requirement) == errSecSuccess else { return false }
    // Bind caller to the actual installed code, rather than trusting an identifier alone.
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: expectedParent) as CFURL,
        SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return false }
    var designated: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &designated) == errSecSuccess,
          SecCodeCheckValidity(dynamicCode, SecCSFlags(), designated) == errSecSuccess else { return false }
    return true
}

func withInteraction<T>(_ enabled: Bool = false, _ body: () throws -> T) throws -> T {
    var previous = DarwinBoolean(true)
    let read = SecKeychainGetUserInteractionAllowed(&previous)
    guard read == errSecSuccess else { throw VaultError(status: read) }
    let status = SecKeychainSetUserInteractionAllowed(enabled)
    guard status == errSecSuccess else { throw VaultError(status: status) }
    defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
    return try body()
}
func query(_ service: String, _ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service, kSecAttrAccount as String: account]
}
func read(_ service: String, _ account: String) throws -> String? {
    var q = query(service, account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
          let value = String(data: data, encoding: .utf8) else { throw VaultError(status: status) }
    return value
}
func write(_ value: String, service: String, account: String) throws {
    let q = query(service, account)
    let attributes = [kSecValueData as String: Data(value.utf8)]
    var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
        var add = q; add[kSecValueData as String] = Data(value.utf8)
        status = SecItemAdd(add as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw VaultError(status: status) }
    guard try read(service, account) == value else { throw VaultError(status: errSecDecode) }
}
func loadVault() throws -> [String: String] {
    guard let text = try read(vaultService, "vault") else { return [:] }
    return try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
}
func saveVault(_ values: [String: String]) throws {
    let data = try JSONEncoder().encode(values)
    try write(String(decoding: data, as: UTF8.self), service: vaultService, account: "vault")
}
func validPayload(_ payload: String) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty else { return false }
    return true
}
func handle(_ request: Request) throws -> Reply {
    switch request.operation {
    case "load": return Reply(ok: true, values: try loadVault())
    case "put":
        guard let incoming = request.values else { return Reply(ok: false, error: "invalid request") }
        var values = try loadVault()
        values.merge(incoming) { _, new in new }
        try saveVault(values)
        return Reply(ok: true)
    case "remove":
        guard let key = request.key else { return Reply(ok: false, error: "invalid request") }
        var values = try loadVault(); values.removeValue(forKey: key)
        try saveVault(values)
        return Reply(ok: true)
    case "live-read": return Reply(ok: true, value: try read(liveService, NSUserName()))
    case "live-write":
        guard let value = request.value, validPayload(value),
              let previous = try read(liveService, NSUserName()) else {
            return Reply(ok: false, error: "current credentials unavailable; unchanged")
        }
        do {
            try write(value, service: liveService, account: NSUserName())
            return Reply(ok: true)
        } catch {
            try? write(previous, service: liveService, account: NSUserName())
            throw error
        }
    case "switch":
        // This operation is called only by the user's explicit Switch button.
        return try withInteraction(true) {
            guard let value = request.value, validPayload(value),
                  let previous = try read(liveService, NSUserName()) else {
                return Reply(ok: false, error: "current credentials unavailable; unchanged")
            }
            var values = try loadVault(); values["rollback:live"] = previous
            try saveVault(values)
            do {
                try write(value, service: liveService, account: NSUserName())
                return Reply(ok: true)
            } catch {
                do { try write(previous, service: liveService, account: NSUserName()) }
                catch { return Reply(ok: false, error: "switch failed; rollback failed") }
                return Reply(ok: false, error: "switch failed; previous credentials restored")
            }
        }
    case "legacy-read":
        // Best-effort, strictly noninteractive recovery from the previous GUI-owned vault.
        guard let key = request.key else { return Reply(ok: false, error: "invalid request") }
        return Reply(ok: true, value: try read("dev.rebon.quotabar.secrets", key))
    #if VAULT_TESTING
    case "test-init-live":
        guard let value = request.value else { return Reply(ok: false) }
        try write(value, service: liveService, account: NSUserName()); return Reply(ok: true)
    case "test-cleanup":
        SecItemDelete(query(vaultService, "vault") as CFDictionary)
        SecItemDelete(query(liveService, NSUserName()) as CFDictionary)
        return Reply(ok: true)
    #endif
    default: return Reply(ok: false, error: "unsupported operation")
    }
}
func finish(_ reply: Reply) -> Never {
    if let data = try? JSONEncoder().encode(reply) { FileHandle.standardOutput.write(data) }
    exit(reply.ok ? 0 : 1)
}

guard callerIsTrusted() else { finish(Reply(ok: false, error: "untrusted caller")) }
let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
guard fd >= 0 else { finish(Reply(ok: false, error: "cannot lock credential store")) }
defer { close(fd) }
guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { finish(Reply(ok: false, error: "credential store busy")) }
let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= 8 * 1024 * 1024,
      let request = try? JSONDecoder().decode(Request.self, from: input) else {
    finish(Reply(ok: false, error: "invalid request"))
}
do { finish(try withInteraction { try handle(request) }) }
catch let error as VaultError {
    finish(Reply(ok: false, status: error.status, error: "keychain access unavailable"))
} catch { finish(Reply(ok: false, error: "credential operation failed")) }

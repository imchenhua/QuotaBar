// Live Claude item bridge: Apple tooling owns every token write. Native APIs read metadata only.
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

#if BRIDGE_TESTING
let liveService = ProcessInfo.processInfo.environment["QUOTABAR_TEST_LIVE_SERVICE"]!
let expectedParent = ProcessInfo.processInfo.environment["QUOTABAR_TEST_PARENT"]!
let expectedIdentifier = "dev.rebon.quotabar.tests"
#else
let liveService = "Claude Code-credentials"
let expectedParent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/QuotaBar.app/Contents/MacOS/QuotaBar").path
let expectedIdentifier = "dev.rebon.quotabar"
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

func query(_ service: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service, kSecAttrAccount as String: NSUserName()]
}
func ref(_ service: String) throws -> SecKeychainItem {
    var q = query(service); q[kSecReturnRef as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    guard status == 0, let result else { throw VaultError(status: status) }
    return result as! SecKeychainItem
}
func canReadSilently(_ service: String) -> Bool {
    guard let item = try? ref(service) else { return false }
    var keychain: SecKeychain?
    guard SecKeychainItemCopyKeychain(item, &keychain) == 0, let keychain else { return false }
    var status: SecKeychainStatus = 0
    guard SecKeychainGetStatus(keychain, &status) == 0,
          status & UInt32(kSecUnlockStateStatus) != 0 else { return false }
    var access: SecAccess?, entries: CFArray?
    guard SecKeychainItemCopyAccess(item, &access) == 0, let access,
          SecAccessCopyACLList(access, &entries) == 0, let entries else { return false }
    var partitionOK = false, applicationOK = false
    for acl in entries as! [SecACL] {
        let auths = SecACLCopyAuthorizations(acl) as? [String] ?? []
        var apps: CFArray?, description: CFString?
        var prompt = SecKeychainPromptSelector(rawValue: 0)
        guard SecACLCopyContents(acl, &apps, &description, &prompt) == 0 else { continue }
        if auths.contains(kSecACLAuthorizationDecrypt as String) {
            if prompt.contains(.requirePassphase) { continue }
            if apps == nil { applicationOK = true }
            for app in (apps as? [SecTrustedApplication] ?? []) {
                var data: CFData?
                if SecTrustedApplicationCopyData(app, &data) == 0, let data,
                   let path = String(data: data as Data, encoding: .utf8),
                   path.trimmingCharacters(in: .controlCharacters) == "/usr/bin/security" { applicationOK = true }
            }
        }
        if auths.contains(kSecACLAuthorizationPartitionID as String), let text = description as String? {
            var bytes = Data(); var i = text.startIndex
            while i < text.endIndex {
                let end = text.index(i, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                guard text.distance(from: i, to: end) == 2, let byte = UInt8(text[i..<end], radix: 16) else { break }
                bytes.append(byte); i = end
            }
            if let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
               let parts = plist["Partitions"] as? [String] { partitionOK = parts.contains("apple-tool:") }
        }
    }
    return partitionOK && applicationOK
}
func quoted(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
func security(_ args: [String], command: String? = nil) throws -> Data {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security"); p.arguments = args
    let output = Pipe(), input = Pipe()
    p.standardOutput = output; p.standardError = FileHandle.nullDevice; p.standardInput = input
    try p.run()
    DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if p.isRunning { p.terminate() } }
    if let command { try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8)) }
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw VaultError(status: errSecAuthFailed) }
    return data
}
func read(_ service: String) throws -> String {
    guard canReadSilently(service) else { throw VaultError(status: errSecInteractionNotAllowed) }
    return String(decoding: try security(["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]), as: UTF8.self)
        .trimmingCharacters(in: .newlines)
}
func write(_ value: String, service: String) throws {
    // Credentials are passed via stdin, never argv, shell expansion, files, or logs.
    guard let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { throw VaultError(status: errSecDecode) }
    let payload = String(decoding: canonical, as: UTF8.self)
    let exists = (try? ref(service)) != nil
    if exists && !canReadSilently(service) { throw VaultError(status: errSecInteractionNotAllowed) }
    var command = "add-generic-password -U -s \(quoted(service)) -a \(quoted(NSUserName())) -w \(quoted(payload))"
    if !exists {
        command += " -T /usr/bin/security"
        let claude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
        if FileManager.default.isExecutableFile(atPath: claude) { command += " -T " + quoted(claude) }
    }
    _ = try security(["-i"], command: command)
    guard try read(service) == payload else { throw VaultError(status: errSecDecode) }
}
func valid(_ value: String) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { return false }
    return !token.isEmpty
}
func handle(_ request: Request) throws -> Reply {
    switch request.operation {
    case "read": return Reply(ok: true, value: try read(liveService))
    case "write":
        guard let value = request.value, valid(value) else { return Reply(ok: false, error: "invalid payload") }
        let previous = try read(liveService)
        do { try write(value, service: liveService) }
        catch { try? write(previous, service: liveService); throw error }
        return Reply(ok: true)
    case "migrate":
        guard let value = request.value, valid(value) else { return Reply(ok: false, error: "invalid payload") }
        _ = try ref(liveService) // No missing-item bootstrap or account changes.
        let staging = liveService + ".quotabar-recovery." + UUID().uuidString
        try write(value, service: staging) // Durable, Apple-owned recovery copy before touching the live item.
        _ = try security(["delete-generic-password", "-s", liveService, "-a", NSUserName()])
        do { try write(value, service: liveService) }
        catch {
            // Retain the recovery item on any failure. Its name contains no secret.
            throw VaultError(status: errSecNotAvailable)
        }
        _ = try? security(["delete-generic-password", "-s", staging, "-a", NSUserName()])
        return Reply(ok: true)
    #if BRIDGE_TESTING
    case "test-native-create":
        var q = query(liveService); q[kSecValueData as String] = Data(request.value!.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == 0 else { throw VaultError(status: status) }
        return Reply(ok: true)
    case "test-create":
        guard let value = request.value else { return Reply(ok: false) }
        try write(value, service: liveService); return Reply(ok: true)
    case "test-cleanup":
        _ = try? security(["delete-generic-password", "-s", liveService, "-a", NSUserName()]); return Reply(ok: true)
    #endif
    default: return Reply(ok: false, error: "unsupported operation")
    }
}

func finish(_ reply: Reply) -> Never {
    if let data = try? JSONEncoder().encode(reply) { FileHandle.standardOutput.write(data) }
    exit(reply.ok ? 0 : 1)
}
guard callerIsTrusted() else { finish(Reply(ok: false, error: "untrusted caller")) }
let raw = FileHandle.standardInput.readDataToEndOfFile()
guard raw.count < 1_048_576, let request = try? JSONDecoder().decode(Request.self, from: raw) else {
    finish(Reply(ok: false, error: "invalid request"))
}
do { finish(try withInteraction { try handle(request) }) }
catch let error as VaultError { finish(Reply(ok: false, status: error.status, error: "live credential unavailable; no automatic authorization")) }
catch { finish(Reply(ok: false, error: "live credential operation failed")) }

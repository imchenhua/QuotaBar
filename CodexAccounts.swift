import AppKit
import Combine
import Foundation

/// Each added account gets its own CLI home; adding an account never replaces ~/.codex/auth.json.
@MainActor
final class CodexAccounts: ObservableObject {
    static let shared = CodexAccounts()
    @Published private(set) var stores: [CodexQuotaStore] = [.shared]
    @Published private(set) var signingIn = false
    @Published private(set) var loginNote: String?
    private var loginProcess: Process?
    private var pendingID: String?
    private var timeout: Task<Void, Never>?
    private var observations: [AnyCancellable] = []
    private let root: URL
    private let loginExecutable: URL?
    private let autoStartAdded: Bool
    private var indexURL: URL { root.appendingPathComponent("accounts.json") }
    private var ids: [String] = []
    var refreshing: Bool { stores.contains { $0.refreshing } }

    init(storedRoot: URL? = nil, loginExecutable: URL? = CodexQuotaProbe.executable, autoStartAdded: Bool = true) {
        root = storedRoot ?? Paths.configDir.appendingPathComponent("codex-accounts", isDirectory: true)
        self.loginExecutable = loginExecutable
        self.autoStartAdded = autoStartAdded
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([String].self, from: data) {
            ids = Array(Set(saved.filter { UUID(uuidString: $0) != nil })).sorted()
            stores += ids.map { CodexQuotaStore(id: $0, home: root.appendingPathComponent($0, isDirectory: true)) }
        }
        observe()
    }

    private func observe() {
        observations = stores.map { store in
            store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        }
    }

    func start() { stores.forEach { $0.start() } }
    func refreshNow() { stores.forEach { $0.refreshNow() } }

    func addAccount() {
        guard !signingIn, let executable = loginExecutable else {
            if !signingIn { loginNote = "未找到 Codex CLI" }
            return
        }
        let id = UUID().uuidString
        let home = root.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try privateWrite(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: home.appendingPathComponent("config.toml"))
            let process = Process()
            process.executableURL = executable
            process.arguments = ["login"]
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = home.path
            environment.removeValue(forKey: "OPENAI_API_KEY")
            environment.removeValue(forKey: "CODEX_API_KEY")
            process.environment = environment
            process.currentDirectoryURL = home
            // CLI opens the normal browser OAuth flow. Never retain its URLs, codes, or output in logs.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] child in
                Task { @MainActor in self?.completed(id: id, status: child.terminationStatus) }
            }
            pendingID = id
            loginProcess = process
            signingIn = true
            loginNote = "请在浏览器完成 GPT 登录；当前 Codex 登录保持不变。"
            try process.run()
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                guard !Task.isCancelled else { return }
                self?.cancelLogin()
                self?.loginNote = "登录已超时，请重新添加"
            }
        } catch {
            pendingID = nil
            signingIn = false
            loginProcess = nil
            loginNote = "无法启动 GPT 登录，请稍后重试"
            discardUnregistered(id)
        }
    }

    private func completed(id: String, status: Int32) {
        guard pendingID == id else { return }
        timeout?.cancel(); timeout = nil
        pendingID = nil
        signingIn = false
        loginProcess = nil
        guard status == 0 else {
            loginNote = "GPT 登录未完成，可以重新添加"
            discardUnregistered(id)
            return
        }
        let home = root.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path) else {
            loginNote = "GPT 登录未保存，请重新添加"
            discardUnregistered(id)
            return
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent("auth.json").path)
            let updated = ids + [id]
            try privateWrite(try JSONEncoder().encode(updated), to: indexURL)
            ids = updated
            let store = CodexQuotaStore(id: id, home: home)
            stores.append(store)
            observe()
            if autoStartAdded { store.start() }
            loginNote = "GPT 账号已添加"
        } catch { loginNote = "登录已完成，但账号登记失败，请重试" }
    }

    func cancelLogin() {
        let id = pendingID
        pendingID = nil
        timeout?.cancel(); timeout = nil
        if let process = loginProcess, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        loginProcess = nil
        signingIn = false
        loginNote = nil
        if let id { discardUnregistered(id) }
    }

    func remove(_ store: CodexQuotaStore) {
        guard store.id != "current", !store.refreshing, UUID(uuidString: store.id) != nil else { return }
        do {
            let remaining = ids.filter { $0 != store.id }
            try privateWrite(try JSONEncoder().encode(remaining), to: indexURL)
            store.stop()
            ids = remaining
            stores.removeAll { $0.id == store.id }
            observe()
            // Preserve credentials for undo; this action removes only QuotaBar's registration.
            loginNote = "已移除该账号的额度卡片"
        } catch { loginNote = "账号移除失败，请重试" }
    }

    private func discardUnregistered(_ id: String) {
        guard UUID(uuidString: id) != nil, !ids.contains(id) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
    }
}

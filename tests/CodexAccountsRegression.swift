import Foundation

@main struct CodexAccountsRegression {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-logins-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex-login")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "tests/fixtures/codex-login.py"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let root = directory.appendingPathComponent("accounts")
        let accounts = CodexAccounts(storedRoot: root, loginExecutable: executable, autoStartAdded: false)
        let realAuth = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        let original = try? Data(contentsOf: realAuth)
        func scenario(_ value: String) throws {
            try value.write(to: directory.appendingPathComponent("login-scenario.txt"), atomically: true, encoding: .utf8)
        }
        func settle() async throws {
            for _ in 0..<100 {
                if !accounts.signingIn { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            preconditionFailure("Login completion must be bounded")
        }
        try scenario("success")
        accounts.addAccount()
        accounts.addAccount() // A second click must not start a second flow.
        try await settle()
        precondition(accounts.stores.count == 2)
        let added = accounts.stores[1]
        precondition(added.home?.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path)
        let auth = added.home!.appendingPathComponent("auth.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: auth.path)
        precondition((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let reloaded = CodexAccounts(storedRoot: root, loginExecutable: executable, autoStartAdded: false)
        precondition(reloaded.stores.map(\.id).contains(added.id), "Account registration survives relaunch")
        accounts.remove(added)
        precondition(accounts.stores.count == 1 && FileManager.default.fileExists(atPath: auth.path), "Removing a card preserves credentials for undo")
        try scenario("failure")
        accounts.addAccount()
        try await settle()
        precondition(accounts.stores.count == 1, "Failed login must not register an account")
        try scenario("cancel")
        accounts.addAccount()
        try await Task.sleep(nanoseconds: 150_000_000)
        accounts.cancelLogin()
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(!accounts.signingIn && accounts.stores.count == 1)
        precondition((try? Data(contentsOf: realAuth)) == original, "Adding or cancelling a GPT account never changes current Codex auth")
        print("PASS: GPT isolated login, repeated-click guard, success, failure, cancellation, private auth permissions, persistence, removal, current auth unchanged")
    }
}

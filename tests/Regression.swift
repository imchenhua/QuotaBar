import Foundation

@main
struct Regression {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
    static func main() throws {
        var switchOperations: [String] = []
        do {
            try KeychainCredentials.switchLive("fixture") { operation, _ in
                switchOperations.append(operation)
                return AgentReply(ok: false, values: nil, value: nil, status: -25308, error: "interaction denied")
            }
            fatalError("Denied silent switch must fail")
        } catch { }
        check(switchOperations == ["write"], "Ordinary switching must never retry with an interactive Keychain request")
        try KeychainCredentials.switchLive("fixture") { operation, _ in
            switchOperations.append(operation)
            return AgentReply(ok: true, values: nil, value: nil, status: nil, error: nil)
        }
        check(switchOperations == ["write", "write"], "Retries must continue to use the Apple bridge without an interactive fallback")
        let identityDir = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: identityDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: identityDir) }
        let identityFile = identityDir.appendingPathComponent("claude.json")
        let identityBackups = identityDir.appendingPathComponent("backups")
        let originalConfig: [String: Any] = ["oauthAccount": ["emailAddress": "old@example.invalid", "organizationUuid": "old-org", "accountUuid": "old-uuid", "oldAccountFlag": true], "projects": ["/work": ["hasTrustDialogAccepted": true]], "mcpServers": ["example": ["command": "keep-me"]]]
        let originalData = try JSONSerialization.data(withJSONObject: originalConfig)
        try originalData.write(to: identityFile)
        let identityProfile = try JSONDecoder().decode(OAuthProfile.self, from: Data(#"{"account":{"uuid":"new-uuid","email":"new@example.invalid","full_name":"New"},"organization":{"uuid":"new-org","billing_type":"apple_subscription"}}"#.utf8))
        let identityAccount = Account(name: "New", email: "new@example.invalid", org: "new-org", sessionKey: "")
        let oldPayload = #"{"claudeAiOauth":{"accessToken":"OLD-FAKE"}}"#
        let newPayload = #"{"claudeAiOauth":{"accessToken":"NEW-FAKE"}}"#
        var currentPayload = oldPayload
        try ClaudeAccountSwitch.commit(payload: newPayload, profile: identityProfile, account: identityAccount,
            identityURL: identityFile, backupDirectory: identityBackups, read: { currentPayload }, write: { currentPayload = $0 })
        check(currentPayload == newPayload && ClaudeIdentityStore.matches(identityAccount, at: identityFile), "Switch must update both token and Claude identity")
        let switchedConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: identityFile)) as! [String: Any]
        check((switchedConfig["projects"] as? NSDictionary) == (originalConfig["projects"] as? NSDictionary), "Preserve project trust settings")
        check((switchedConfig["mcpServers"] as? NSDictionary) == (originalConfig["mcpServers"] as? NSDictionary), "Preserve MCP settings")
        check((switchedConfig["oauthAccount"] as? [String: Any])?["oldAccountFlag"] == nil, "Never carry another account's feature flags")
        let identityPermissions = try FileManager.default.attributesOfItem(atPath: identityFile.path)
        check((identityPermissions[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Identity file remains private")
        let identityBackupFiles = try FileManager.default.contentsOfDirectory(atPath: identityBackups.path)
        check(!identityBackupFiles.isEmpty, "Keep a durable identity backup")
        // A failed identity commit must restore the original credential.
        currentPayload = oldPayload
        try Data("invalid-json".utf8).write(to: identityFile)
        var writes = 0
        do {
            try ClaudeAccountSwitch.commit(payload: newPayload, profile: identityProfile, account: identityAccount,
                identityURL: identityFile, backupDirectory: identityBackups, read: { currentPayload }, write: { currentPayload = $0; writes += 1 })
            fatalError("Malformed identity configuration must refuse switching")
        } catch { }
        check(currentPayload == oldPayload && writes == 0, "Malformed config must fail before touching shared credentials")
        try originalData.write(to: identityFile)
        var reads = 0
        do {
            try ClaudeAccountSwitch.commit(payload: newPayload, profile: identityProfile, account: identityAccount,
                identityURL: identityFile, backupDirectory: identityBackups,
                read: { reads += 1; return reads == 2 ? oldPayload : currentPayload }, write: { currentPayload = $0 })
            fatalError("Inconsistent post-switch state must not report success")
        } catch { }
        check(currentPayload == oldPayload, "Post-switch verification failure rolls back shared credential")
        let restored = try ClaudeIdentityStore.read(at: identityFile)
        check(restored?["accountUuid"] as? String == "old-uuid", "Post-switch verification failure restores original identity")
        print("PASS: complete account switch, preserved settings, private backup, malformed input, and rollback of both stores")
        let sharedPayload = #"{"claudeAiOauth":{"accessToken":"LIVE-FAKE","refreshToken":"SHARED-REFRESH"}}"#
        let sharedOlderPayload = #"{"claudeAiOauth":{"accessToken":"OLD-ACCESS","refreshToken":"SHARED-REFRESH"}}"#
        let privatePayload = #"{"claudeAiOauth":{"accessToken":"PRIVATE-FAKE","refreshToken":"PRIVATE-REFRESH"}}"#
        check(!canRefreshPrivateCredential(sharedPayload, accountKey: "current", livePayload: sharedPayload, liveAccountKey: "current"), "CLI-owned login must never be independently refreshed")
        check(!canRefreshPrivateCredential(sharedOlderPayload, accountKey: "other", livePayload: sharedPayload, liveAccountKey: "current"), "Shared refresh token must never be rotated by the monitor")
        check(!canRefreshPrivateCredential(privatePayload, accountKey: "other", livePayload: sharedPayload, liveAccountKey: nil), "Unknown live owner must fail closed for background refresh")
        check(!canRefreshPrivateCredential(privatePayload, accountKey: "other", livePayload: nil, liveAccountKey: nil), "Unreadable shared credentials must never be treated as an independent account")
        check(canRefreshPrivateCredential(privatePayload, accountKey: "other", livePayload: sharedPayload, liveAccountKey: "current"), "Independent inactive account remains refreshable")
        let leases = identityDir.appendingPathComponent("leases")
        var lease = OAuthRefreshLease.acquire("account", directory: leases)
        check(lease != nil && OAuthRefreshLease.acquire("account", directory: leases) == nil, "Concurrent refresh of the same account must be excluded")
        lease = nil
        let afterRelease = OAuthRefreshLease.acquire("account", directory: leases)
        check(afterRelease != nil, "Refresh lease is released after scope exit")
        withExtendedLifetime(afterRelease) {}
        let cliLock = identityDir.appendingPathComponent(".oauth_refresh.lock")
        try FileManager.default.createDirectory(at: cliLock, withIntermediateDirectories: false)
        check(claudeRefreshInProgress(directory: identityDir), "Switch must notice Claude Code's in-flight refresh")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: cliLock.path)
        check(!claudeRefreshInProgress(directory: identityDir), "Stale CLI lock must not block switching forever")
        print("PASS: shared-token refresh exclusion, unknown owner, per-account refresh serialization, CLI refresh lock")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = now.addingTimeInterval(900)
        let earlier = now.addingTimeInterval(-60)
        let success = Snapshot(fetchedAt: earlier, error: nil)
        let limited = Snapshot(fetchedAt: earlier, error: "HTTP 429")
        check(quotaRefreshGate(manual: true, nextEligible: later, lastAttempt: earlier, lastResult: success, now: now) == nil,
              "Manual refresh must fetch during the normal fifteen-minute polling interval")
        check(quotaRefreshGate(manual: false, nextEligible: later, lastAttempt: earlier, lastResult: success, now: now) == later,
              "Background polling must retain its interval")
        check(quotaRefreshGate(manual: true, nextEligible: later, lastAttempt: earlier, lastResult: limited, now: now) == later,
              "Manual refresh must not bypass persisted HTTP 429 cooldown")
        let fallbackLimited = Snapshot(fetchedAt: earlier, error: "凭据过期", retryAfter: 120)
        check(quotaRefreshGate(manual: true, nextEligible: later, lastAttempt: earlier, lastResult: fallbackLimited, now: now) == later,
              "A rate-limited fallback must retain Retry-After")
        check(quotaRefreshGate(manual: true, nextEligible: earlier, lastAttempt: earlier, lastResult: limited, now: now) == nil,
              "Expired limits allow a new request")
        check(quotaRefreshGate(manual: true, nextEligible: later, lastAttempt: now, lastResult: success, now: now) == now.addingTimeInterval(10),
              "Repeated clicks must not produce a request burst")
        check(resetCountdown(now.addingTimeInterval(8100), now: now) == "2h15m", "Hourly countdown")
        check(resetCountdown(now.addingTimeInterval(280800), now: now) == "3d6h", "Weekly countdown")
        check(resetCountdown(now.addingTimeInterval(5 * 86400 + 6 * 3600 + 43 * 60), now: now) == "5d6h43m", "Compact day-hour-minute display")
        check(resetCountdown(now.addingTimeInterval(61), now: now) == "2m", "Do not display zero before a reset")
        check(resetCountdown(now.addingTimeInterval(59), now: now) == "<1m", "Final minute")
        check(resetCountdown(now, now: now) == "待刷新", "Expired cached resets must not claim quota is refreshed")
        check(resetCountdown(nil, now: now) == "—", "Unknown reset stays unknown")
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let authorization = OAuthPKCE.authorizeURL(verifier: verifier, state: "independent-state")!
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        check(query["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 PKCE vector")
        check(query["state"] == "independent-state" && !authorization.absoluteString.contains(verifier),
              "Authorization URL must not expose the PKCE verifier")
        let local = [Account(name: "Local", email: "a", org: "ABC", sessionKey: "valid"),
                     Account(name: "Keep", email: nil, org: "local", sessionKey: "")]
        let incoming = [Account(name: "Imported", email: "a", org: "abc", sessionKey: ""),
                        Account(name: "Added", email: "b", org: "new", sessionKey: "new")]
        let status = CLIAuthStatus(loggedIn: true, authMethod: "claude.ai", email: "A", orgId: "abc")
        check(accountMatchingCLIStatus(status, accounts: local)?.name == "Local", "CLI identity matches case-insensitively")
        let wrongOrg = CLIAuthStatus(loggedIn: true, authMethod: "claude.ai", email: "a", orgId: "wrong")
        check(accountMatchingCLIStatus(wrongOrg, accounts: local) == nil, "Never identify an account by email alone")
        let signedOut = CLIAuthStatus(loggedIn: false, authMethod: "claude.ai", email: "a", orgId: "abc")
        check(accountMatchingCLIStatus(signedOut, accounts: local) == nil, "Signed-out metadata must not become current")
        let apiKey = CLIAuthStatus(loggedIn: true, authMethod: "api_key", email: "a", orgId: "abc")
        check(accountMatchingCLIStatus(apiKey, accounts: local) == nil, "API credentials must not masquerade as an account")
        let merged = mergeImportedAccounts(local, incoming)
        check(merged.count == 3 && merged[0].name == "Local" && merged[0].sessionKey == "valid",
              "Import retains local names, accounts and valid sessions")
        check(mergeImportedAccounts(merged, incoming).count == 3, "Reimport is idempotent")
        let usage = try decodeUsage(Data("""
        {"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":100,"resets_at":"2026-11-01T18:00:00.214201+00:00"},"future_field":{"anything":true}}
        """.utf8), source: "cookie")
        check(usage.fiveHour?.utilization == 0, "A real zero must be retained")
        check(usage.fiveHour?.resetsAt == nil, "A null reset is valid")
        check(usage.sevenDay?.utilization == 100, "Weekly limit")
        check(claudePlanLabel(subscription: "pro", tier: nil) == "Pro", "Claude Pro is read from metadata")
        check(claudePlanLabel(subscription: "max", tier: "default_claude_max_5x") == "Max 5x", "Max 5x tier")
        check(claudePlanLabel(subscription: nil, tier: "default_claude_max_20x") == "Max 20x", "Max 20x fallback")
        check(claudePlanLabel(subscription: "team", tier: "default_claude_max_5x") == "Team", "Explicit subscription takes precedence")
        check(claudePlanLabel(subscription: nil, tier: nil) == nil, "No inferred subscription from usage percentages")
        let weeklyOnly = try decodeUsage(Data(#"{"five_hour":null,"seven_day":{"utilization":40,"resets_at":null}}"#.utf8), source: "oauth")
        check(weeklyOnly.quotaWindows.map(\.id) == ["seven_day"], "Missing 5h is hidden, never displayed as zero")
        let scopedOnly = try decodeUsage(Data(#"{"seven_day_sonnet":{"utilization":17,"resets_at":null},"seven_day_opus":null,"seven_day_bad":{"utilization":true}}"#.utf8), source: "oauth")
        check(scopedOnly.quotaWindows.count == 1 && scopedOnly.quotaWindows.first?.title == "Sonnet", "Valid scoped-only windows survive absent standard windows and malformed siblings")
        let legacy = try JSONDecoder().decode(Snapshot.self, from: Data(#"{"fetchedAt":0,"sevenDay":{"utilization":20}}"#.utf8))
        check(legacy.plan == nil && legacy.quotaWindows.count == 1, "Old snapshot caches remain readable")
        let profile = try JSONDecoder().decode(OAuthProfile.self, from: Data(#"{"account":{"email":"fixture@example.invalid"},"organization":{"uuid":"org","rate_limit_tier":"default_claude_max_20x"}}"#.utf8))
        check(profile.planLabel(payload: #"{"claudeAiOauth":{"subscriptionType":"pro"}}"#) == "Max 20x", "Live same-account profile takes precedence over saved sign-in plan")
        let applePro = try JSONDecoder().decode(OAuthProfile.self, from: Data(#"{"account":{"has_claude_pro":true,"has_claude_max":false},"organization":{"uuid":"org","organization_type":"claude_pro","billing_type":"apple_subscription","rate_limit_tier":"default_claude_ai"}}"#.utf8))
        check(applePro.planLabel(payload: "{}") == "Pro", "Real Apple subscription profile identifies Pro even when rate-limit tier is generic")
        for invalid in ["{}", "{\"five_hour\":null,\"seven_day\":null}",
                        "{\"five_hour\":{\"utilization\":101}}", "{\"five_hour\":{\"utilization\":-1}}"] {
            do { _ = try decodeUsage(Data(invalid.utf8), source: "cookie"); fatalError("Accepted invalid response") }
            catch { }
        }
        let fractional = parseISO("2026-10-29T17:11:50.690166Z")
        check(fractional != nil, "Fractional timestamp")
        let url = URL(string: "https://example.com")!
        let seconds = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                      headerFields: ["Retry-After": "3600"])!
        check(retryAfter(from: seconds) == 3600, "Honor server cooldown beyond local cap")
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let httpDate = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": dateFormatter.string(from: Date().addingTimeInterval(600))])!
        check((retryAfter(from: httpDate) ?? 0) > 590, "HTTP-date Retry-After")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-tests-" + UUID().uuidString)
        let sessions = dir.appendingPathComponent("sessions")
        let cache = dir.appendingPathComponent("cache/scan.json")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = sessions.appendingPathComponent("a.jsonl")
        func line(_ id: String, _ output: Int) -> String {
            "{\"type\":\"assistant\",\"timestamp\":\"2026-10-29T17:00:00Z\",\"message\":{\"id\":\"\(id)\",\"usage\":{\"input_tokens\":10,\"output_tokens\":\(output)}}}"
        }
        func scan() -> TokenStats.ScanResult { TokenStats.scanJSONL(root: sessions, cacheURL: cache) }
        try (line("one", 1) + "\n").write(to: file, atomically: true, encoding: .utf8)
        check(scan().entries.reduce(0) { $0 + $1.total } == 11, "Initial local scan")
        check(scan().entries.reduce(0) { $0 + $1.total } == 11, "Cached scan must not double count")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("one", 5) + "\n" + line("two", 2)).utf8))
        try handle.close()
        check(scan().entries.reduce(0) { $0 + $1.total } == 15, "Streaming update, incomplete last line deferred")
        let append = try FileHandle(forWritingTo: file)
        try append.seekToEnd(); try append.write(contentsOf: Data("\n".utf8)); try append.close()
        check(scan().entries.reduce(0) { $0 + $1.total } == 27, "Completed last line counted once")
        try (line("one", 5) + "\n").write(to: sessions.appendingPathComponent("duplicate.jsonl"), atomically: true, encoding: .utf8)
        check(scan().entries.reduce(0) { $0 + $1.total } == 27, "Deduplicate messages across files")
        try (line("three", 3) + "\n").write(to: file, atomically: true, encoding: .utf8)
        check(scan().entries.reduce(0) { $0 + $1.total } == 28, "Replaced file invalidates cached offsets")
        check(scan().failures == 0, "All fixtures readable")
        let attrs = try FileManager.default.attributesOfItem(atPath: cache.path)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Private cache permissions")
        print("PASS: usage parsing, null reset, invalid responses, Retry-After, incremental scan, streaming deduplication, partial append, file replacement, private cache")
    }
}

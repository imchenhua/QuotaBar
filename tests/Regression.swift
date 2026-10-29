import Foundation

@main
struct Regression {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
    static func main() throws {
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

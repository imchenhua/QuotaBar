import Foundation

@main struct CodexRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func main() throws {
        let account = try JSONDecoder().decode(CodexAccount.self, from: Data(
            #"{"type":"chatgpt","email":"fixture@example.invalid","planType":"prolite"}"#.utf8))
        let weekly = #"{"usedPercent":53,"windowDurationMins":10080,"resetsAt":1793776148}"#
        func decode(_ text: String) throws -> CodexQuotaSnapshot {
            try JSONDecoder().decode(CodexLimitsResponse.self, from: Data(text.utf8))
                .snapshot(account: account, now: Date())
        }
        let single = try decode("{\"rateLimits\":{\"primary\":\(weekly),\"secondary\":null}}")
        check(single.windows.count == 1 && single.windows[0].label == "7天", "A weekly primary is never mislabeled as 5h")
        check(single.windows[0].usedPercent == 53, "Used percent is not remaining percent")
        check(single.windows[0].resetsAt?.timeIntervalSince1970 == 1793776148, "Reset timestamps are Unix seconds")
        let plus = try JSONDecoder().decode(CodexAccount.self, from: Data(
            #"{"type":"chatgpt","email":"plus@example.invalid","planType":"plus"}"#.utf8))
        let both = try JSONDecoder().decode(CodexLimitsResponse.self, from: Data("""
        {"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1793300000},
                       "secondary":\(weekly)}}
        """.utf8)).snapshot(account: plus, now: Date())
        check(both.email == "plus@example.invalid" && both.plan == "plus", "Quota belongs to its own account and plan")
        check(both.windows.map(\.label) == ["5小时", "7天"], "A Plus account with two windows displays both")
        let plusWeeklyOnly = try JSONDecoder().decode(CodexLimitsResponse.self,
            from: Data("{\"rateLimits\":{\"primary\":\(weekly)}}".utf8)).snapshot(account: plus, now: Date())
        check(plusWeeklyOnly.windows.count == 1 && plusWeeklyOnly.windows[0].label == "7天",
              "Never invent a 5h window just because a plan is Plus")
        let multi = try decode("""
        {"rateLimits":null,"rateLimitsByLimitId":{
          "spark":{"limitName":"Spark","primary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":null}},
          "codex":{"primary":\(weekly)}}}
        """)
        check(multi.windows.count == 2 && multi.windows[0].bucket == "Codex", "Multi-bucket quotas retain separate windows")
        check(multi.windows[1].label == "5小时" && multi.windows[1].resetsAt == nil, "Missing reset remains unknown")
        do {
            _ = try decode(#"{"rateLimits":{"primary":null,"secondary":null}}"#)
            preconditionFailure("Empty limits must not become a zero quota")
        } catch CodexQuotaError.noWindows { }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-codex-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "tests/fixtures/codex-protocol.py"), to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        for scenario in ["success", "signedout", "apikey", "identitychanged", "limited", "timeout"] {
            try scenario.write(to: directory.appendingPathComponent("scenario.txt"), atomically: true, encoding: .utf8)
            let start = Date()
            do {
                let value = try CodexQuotaProbe.read(executable: script, timeout: scenario == "timeout" ? 0.3 : 5)
                check(scenario == "success" && value.windows.first?.usedPercent == 53, "Unexpected probe success")
            } catch let error as CodexQuotaError {
                switch (scenario, error) {
                case ("signedout", .signedOut), ("apikey", .apiKey), ("identitychanged", .identityChanged),
                     ("limited", .rateLimited), ("timeout", .timeout): break
                default: preconditionFailure("Unexpected error for \(scenario): \(error)")
                }
            }
            check(Date().timeIntervalSince(start) < 6, "Every subprocess is bounded and cleaned up")
        }
        let methods = try String(contentsOf: directory.appendingPathComponent("methods.jsonl"), encoding: .utf8)
        for line in methods.split(separator: "\n") {
            let method = try JSONDecoder().decode(String.self, from: Data(line.utf8))
            check(["initialize", "initialized", "account/read", "account/rateLimits/read"].contains(method),
                  "Probe must never start model work, log out, or consume credits")
        }
        print("PASS: Codex quota windows, units, missing data, split/coalesced RPC framing, identity changes, auth modes, rate limits, timeout, read-only protocol")
    }
}

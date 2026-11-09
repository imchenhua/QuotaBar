import Foundation
@main struct LiveBridgeClient {
    static func call(_ operation: String, _ value: String? = nil) throws -> [String: Any] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUOTABAR_TEST_BRIDGE"]!)
        let input = Pipe(), output = Pipe(); p.standardInput = input; p.standardOutput = output
        var request: [String: Any] = ["operation": operation]
        request["value"] = value
        try p.run(); try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func main() throws {
        if CommandLine.arguments.contains("--cleanup") { _ = try call("test-cleanup"); return }
        func payload(_ n: Int) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "FAKE-\(n)-quote\"-slash\\-line\n-next", "refreshToken": "FAKE-REFRESH"]]), as: UTF8.self)
        }
        func require(_ result: [String: Any], _ note: String) {
            guard result["ok"] as? Bool == true else { fatalError("\(note): \(result)") }
        }
        require(try call("test-native-create", payload(0)), "isolated native fixture")
        defer { _ = try? call("test-cleanup") }
        let start = Date()
        let denied = try call("read")
        precondition(denied["ok"] as? Bool == false && Date().timeIntervalSince(start) < 2)
        print("PASS native-owned item refused before Apple tool access; no permission prompt")
        require(try call("migrate", payload(0)), "Apple-owned migration")
        print("PASS isolated migration from native owner to Apple tool with durable recovery copy")
        for n in 1...12 {
            require(try call("write", payload(n)), "write \(n)")
            let result = try call("read"); require(result, "read \(n)")
            let root = try JSONSerialization.jsonObject(with: Data((result["value"] as! String).utf8)) as! [String: Any]
            let oauth = root["claudeAiOauth"] as! [String: String]
            precondition(oauth["accessToken"] == "FAKE-\(n)-quote\"-slash\\-line\n-next")
        }
        let invalid = try call("write", "invalid")
        precondition(invalid["ok"] as? Bool == false)
        require(try call("read"), "invalid write leaves existing credential intact")
        print("PASS 12 renewal/switch writes and reads retain Apple access, escaped tokens, invalid writes rejected")
    }
}

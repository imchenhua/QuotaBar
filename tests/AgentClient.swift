import Foundation
@main struct AgentClient {
    static func call(_ request: [String: Any]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUOTABAR_TEST_AGENT"]!)
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func require(_ condition: @autoclosure () -> Bool, _ note: String) {
        if !condition() { fatalError(note) }
    }
    static func main() throws {
        let mode = CommandLine.arguments[1]
        if mode == "write" {
            let result = try call(["operation":"put", "values":["test":"FAKE-CREDENTIAL"]])
            require(result["ok"] as? Bool == true, "write own test vault")
            print("PASS test vault created without interaction")
        } else if mode == "read" {
            let result = try call(["operation":"load"])
            require(result["ok"] as? Bool == true, "read own test vault")
            require((result["values"] as? [String:String])?["test"] == "FAKE-CREDENTIAL", "same helper must read across UI updates")
            let payload = "{\"claudeAiOauth\":{\"accessToken\":\"FAKE\"}}"
            let initialized = try call(["operation":"test-init-live", "value":payload])
            require(initialized["ok"] as? Bool == true, "initialize isolated live fixture")
            let live = try call(["operation":"live-read"])
            require(live["value"] as? String == payload, "read isolated live fixture")
            let invalid = try call(["operation":"live-write", "value":"invalid"])
            require(invalid["ok"] as? Bool == false, "invalid switch rejected")
            let unchanged = try call(["operation":"live-read"])
            require(unchanged["value"] as? String == payload, "failed switch leaves original unchanged")
            print("PASS UI update retained credentials; invalid writes rejected")
        } else if mode == "denied" {
            let start = Date()
            let result = try call(["operation":"live-read"])
            require(result["ok"] as? Bool == false, "unauthorized credential read must fail closed")
            require(Date().timeIntervalSince(start) < 2, "denied access must not wait for a permission dialog")
            print("PASS denied Keychain access returned immediately without interaction")
        } else if mode == "cleanup" {
            let result = try call(["operation":"test-cleanup"])
            require(result["ok"] as? Bool == true, "cleanup test-only items")
            print("PASS test-only items removed")
        }
        #if BUILD_TWO
        print("client generation 2")
        #endif
    }
}

import Foundation
@main struct KeychainProbe {
    static func main() {
        let start = Date()
        let value = SecretVault.read(key: CommandLine.arguments.dropFirst().first ?? "nonexistent")
        print("readable=\(value != nil) elapsed=\(Date().timeIntervalSince(start))")
    }
}

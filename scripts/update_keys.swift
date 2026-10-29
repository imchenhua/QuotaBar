import Foundation
import CryptoKit

// Sparkle supports a base64-encoded 32-byte Ed25519 seed. Never print the private key.
let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/quotabar-update-signing")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let file = directory.appendingPathComponent("ed25519.key")
let key: Curve25519.Signing.PrivateKey
if FileManager.default.fileExists(atPath: file.path) {
    let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let bytes = Data(base64Encoded: text) else { fatalError("Invalid signing key") }
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
} else {
    key = Curve25519.Signing.PrivateKey()
    try (key.rawRepresentation.base64EncodedString() + "\n").write(to: file, atomically: true, encoding: .utf8)
}
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
print(key.publicKey.rawRepresentation.base64EncodedString())

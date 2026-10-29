import Foundation
import Security
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "dev.rebon.quotabar.agent.tests.live",
    kSecAttrAccount as String: NSUserName()]
var previous = DarwinBoolean(true)
SecKeychainGetUserInteractionAllowed(&previous)
SecKeychainSetUserInteractionAllowed(false)
defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
if CommandLine.arguments.contains("create") {
    var item = query
    item[kSecValueData as String] = Data("FAKE-DENIED-CREDENTIAL".utf8)
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { fatalError("fixture creation failed") }
} else {
    guard SecItemDelete(query as CFDictionary) == errSecSuccess else { fatalError("fixture cleanup failed") }
}

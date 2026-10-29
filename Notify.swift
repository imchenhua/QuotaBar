// Native notifications. Startup never requests permission or runs a scripting fallback.
import AppKit
import Foundation
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var authorized = false
    private var lastSent: [String: Date] = [:]

    func prepare(userInitiated: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                self.authorized = settings.authorizationStatus == .authorized
                guard userInitiated, settings.authorizationStatus == .notDetermined else { return }
                center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                    Task { @MainActor in
                        self?.authorized = granted
                        if error != nil { log("通知授权未完成，后台不再请求") }
                    }
                }
            }
        }
    }

    func post(key: String, title: String, body: String) {
        guard AppSettings.shared.notifyEnabled, authorized else { return }
        if let last = lastSent[key], Date().timeIntervalSince(last) < 600 { return }
        lastSent[key] = Date()
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let request = UNNotificationRequest(identifier: "\(key)-\(Int(Date().timeIntervalSince1970))",
                                             content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil { log("通知发送失败，已跳过；不触发其他授权方式") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

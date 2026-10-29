// QuotaBar 网络层：OAuth 凭据、用量、身份、服务状态。
// 全部走 URLSession，带硬超时，没有任何常驻 WebView。

import Foundation
import CryptoKit
import CoreFoundation

struct UsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }
    let five_hour: Window?
    let seven_day: Window?
}

struct FetchError: Error, CustomStringConvertible {
    let description: String
}

enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scope = "user:inference user:profile"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
}

enum OAuthPKCE {
    static func authorizeURL(verifier: String, state: String) -> URL? {
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents(string: ClaudeOAuth.authorizeURL)
        components?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeOAuth.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: ClaudeOAuth.redirectURI),
            URLQueryItem(name: "scope", value: ClaudeOAuth.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }
}

func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
    guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
        .trimmingCharacters(in: .whitespaces) else { return nil }
    if let seconds = Double(raw), seconds.isFinite { return max(seconds, 30) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: raw).map { max($0.timeIntervalSinceNow, 30) }
}

func decodeUsage(_ data: Data, source: String, now: Date = Date()) throws -> Snapshot {
    let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
    func convert(_ window: UsageResponse.Window?) throws -> UsageWindow? {
        guard let window else { return nil }
        if let pct = window.utilization, !pct.isFinite || !(0...100).contains(pct) {
            throw FetchError(description: "用量百分比无效")
        }
        return UsageWindow(utilization: window.utilization, resetsAt: parseISO(window.resets_at))
    }
    let five = try convert(decoded.five_hour)
    let seven = try convert(decoded.seven_day)
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    var additional: [ClaudeQuotaWindow] = []
    for key in root.keys.sorted() where key.hasPrefix("seven_day_") {
        guard !key.contains("design"), !key.contains("omelette"),
              let value = root[key] as? [String: Any], let number = value["utilization"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
        let pct = number.doubleValue
        guard pct.isFinite, (0...100).contains(pct) else { continue }
        let suffix = String(key.dropFirst("seven_day_".count))
        let title = ["sonnet": "Sonnet", "opus": "Opus", "oauth_apps": "OAuth Apps",
                     "routines": "Routines", "cowork": "Cowork"][suffix] ?? suffix.replacingOccurrences(of: "_", with: " ")
        additional.append(ClaudeQuotaWindow(id: key, title: title, label: "7d",
            window: UsageWindow(utilization: pct, resetsAt: parseISO(value["resets_at"] as? String))))
    }
    guard five?.utilization != nil || seven?.utilization != nil || !additional.isEmpty else {
        throw FetchError(description: "响应没有可用额度窗口")
    }
    return Snapshot(fiveHour: five, sevenDay: seven, fetchedAt: now,
                    error: nil, source: source, additionalWindows: additional)
}

func oauthSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 20
    return URLSession(configuration: config)
}

struct OAuthProfile: Decodable {
    struct Profile: Decodable {
        let uuid: String?
        let email: String?
        let full_name: String?
        let subscription_type: String?
        let rate_limit_tier: String?
        let has_claude_pro: Bool?
        let has_claude_max: Bool?
    }
    struct Org: Decodable {
        let uuid: String
        let subscription_type: String?
        let rate_limit_tier: String?
        let organization_type: String?
    }
    let account: Profile
    let organization: Org?

    func planLabel(payload: String) -> String? {
        let metadata = oauthDictionary(payload)
        return claudePlanLabel(subscription: organization?.subscription_type ?? account.subscription_type ?? organization?.organization_type,
                               tier: organization?.rate_limit_tier ?? account.rate_limit_tier)
            ?? (account.has_claude_max == true ? "Max" : (account.has_claude_pro == true ? "Pro" : nil))
            ?? claudePlanLabel(subscription: metadata?["subscriptionType"] as? String,
                               tier: metadata?["rateLimitTier"] as? String)
    }
}

func fetchProfile(token: String) async -> OAuthProfile? {
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    guard let (data, response) = try? await oauthSession().data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return try? JSONDecoder().decode(OAuthProfile.self, from: data)
}

func fetchOAuthUsage(token: String) async -> Snapshot {
    let now = Date()
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
        return Snapshot(fetchedAt: now, error: "地址无效")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

    do {
        let (data, response) = try await oauthSession().data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return Snapshot(fetchedAt: now, error: "无 HTTP 响应")
        }
        switch http.statusCode {
        case 200:
            return try decodeUsage(data, source: "oauth")
        case 401, 403:
            return Snapshot(fetchedAt: now, error: "凭据过期（\(http.statusCode)）")
        case 429:
            return Snapshot(fetchedAt: now, error: "HTTP 429",
                            retryAfter: retryAfter(from: http))
        default:
            return Snapshot(fetchedAt: now, error: "HTTP \(http.statusCode)")
        }
    } catch let error as FetchError {
        return Snapshot(fetchedAt: now, error: error.description)
    } catch is DecodingError {
        return Snapshot(fetchedAt: now, error: "用量响应格式不兼容")
    } catch {
        return Snapshot(fetchedAt: now,
                        error: (error as NSError).code == NSURLErrorTimedOut ? "超时" : "网络错误")
    }
}

func refreshCredential(_ payload: String) async -> String? {
    guard let refresh = oauthDictionary(payload)?["refreshToken"] as? String,
          let url = URL(string: ClaudeOAuth.tokenURL)
    else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "client_id": ClaudeOAuth.clientID,
    ])

    guard let (data, response) = try? await oauthSession().data(for: request),
          let http = response as? HTTPURLResponse, http.statusCode == 200,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let access = root["access_token"] as? String,
          let newRefresh = (root["refresh_token"] as? String) ?? Optional(refresh)
    else { return nil }

    let expiresIn = (root["expires_in"] as? Double) ?? 28800
    var oauth = oauthDictionary(payload) ?? [:]
    oauth["accessToken"] = access
    oauth["refreshToken"] = newRefresh
    oauth["expiresAt"] = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000)
    guard let data = try? JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys]),
          let result = String(data: data, encoding: .utf8)
    else { return nil }
    return result
}

/// 单次抓取，带硬超时。任何失败都返回带 error 的 Snapshot，由调用方做退避。
func fetchUsage(_ account: Account) async -> Snapshot {
    let now = Date()
    guard account.hasSession else {
        return Snapshot(fetchedAt: now, error: "未登录")
    }
    guard let url = URL(string: "https://claude.ai/api/organizations/\(account.org)/usage") else {
        return Snapshot(fetchedAt: now, error: "组织 ID 无效")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 12
    request.setValue("sessionKey=\(account.sessionKey)", forHTTPHeaderField: "Cookie")
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
    request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")

    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 20
    let session = URLSession(configuration: config)

    do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return Snapshot(fetchedAt: now, error: "无 HTTP 响应")
        }
        switch http.statusCode {
        case 200:
            return try decodeUsage(data, source: "cookie")
        case 401:
            return Snapshot(fetchedAt: now, error: "登录已失效（401）")
        case 403:
            let body = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
            let challenge = body.contains("cloudflare") || body.contains("just a moment") || body.contains("verification")
            return Snapshot(fetchedAt: now, error: challenge
                ? "网页安全验证拦截（403），请用 OAuth 登录"
                : "网页访问被拒绝（403），请重新登录")
        case 429:
            return Snapshot(fetchedAt: now, error: "HTTP 429",
                            retryAfter: retryAfter(from: http))
        default:
            return Snapshot(fetchedAt: now, error: "HTTP \(http.statusCode)")
        }
    } catch let error as FetchError {
        return Snapshot(fetchedAt: now, error: error.description)
    } catch is DecodingError {
        return Snapshot(fetchedAt: now, error: "用量响应格式不兼容")
    } catch {
        return Snapshot(fetchedAt: now,
                        error: (error as NSError).code == NSURLErrorTimedOut ? "超时" : "网络错误")
    }
}

// MARK: - 登录后取账号信息

struct AccountIdentity: Decodable {
    struct Membership: Decodable {
        struct Org: Decodable {
            let uuid: String
            let subscription_type: String?
            let rate_limit_tier: String?
            let billing_type: String?
            let capabilities: [String]?
        }
        let organization: Org
    }
    let email_address: String?
    let full_name: String?
    let memberships: [Membership]?
}

/// 用 sessionKey 问出这个账号的邮箱和组织，顺便验证 key 是否真的可用。
func fetchIdentity(sessionKey: String) async -> AccountIdentity? {
    guard let url = URL(string: "https://claude.ai/api/account") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
    request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
    let session = oauthSession()
    guard let (data, response) = try? await session.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return try? JSONDecoder().decode(AccountIdentity.self, from: data)
}

/// keep-alive：轻量 ping 一次，确认 claude.ai 的 session cookie 还活着。
func pingSession(sessionKey: String) async -> Bool {
    guard let url = URL(string: "https://claude.ai/api/account") else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
    let session = oauthSession()
    guard let (_, response) = try? await session.data(for: request),
          let http = response as? HTTPURLResponse
    else { return false }
    return http.statusCode == 200
}


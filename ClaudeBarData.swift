// 直接复用 ClaudeBar 已经算好的东西。
//
// ClaudeBar（dev.ncthanhngo.claude-bar）把这些都持久化在
// ~/Library/Application Support/claude-swap-widget/ 下：
//   registry.json      账号表（email / org / nickname / 当前号）
//   usage-cache.json   每个号的 5h / 7d 用量（它自己抓的，我们不重复打接口）
//   usage/scan-cache.json  按 15 分钟桶的 token 统计
//   usage/monthly-history.json  月度 token 汇总
//
// 读它的缓存有两个好处：不重复请求（那个 usage 接口限流很紧），
// 以及省掉自己扫 jsonl。缓存过期或者 ClaudeBar 没在跑时，上层再自己去取。

import Foundation

enum ClaudeBarData {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-swap-widget",
                                    isDirectory: true)
    }
    static var registryFile: URL { root.appendingPathComponent("registry.json") }
    static var usageCacheFile: URL { root.appendingPathComponent("usage-cache.json") }
    static var scanCacheFile: URL { root.appendingPathComponent("usage/scan-cache.json") }
    static var monthlyFile: URL { root.appendingPathComponent("usage/monthly-history.json") }

    // MARK: 账号表

    struct Registry: Decodable {
        struct Entry: Decodable {
            let number: Int
            let email: String
            let organizationUuid: String
            let nickname: String
        }
        let activeAccountNumber: Int?
        let accounts: [String: Entry]
    }

    static func registry() -> Registry? {
        guard let data = try? Data(contentsOf: registryFile) else { return nil }
        return try? JSONDecoder().decode(Registry.self, from: data)
    }

    // MARK: 用量缓存

    struct CachedUsage: Decodable {
        struct Window: Decodable {
            let utilizationPct: Double?
            let resetsAt: String?
        }
        let fiveHour: Window?
        let sevenDay: Window?
        let fetchedAt: String?
    }

    private struct CacheEntry: Decodable {
        let usage: CachedUsage?
        let writtenAt: String?
    }

    /// 组织 ID → 缓存用量。
    static func usageByOrg() -> [String: CachedUsage] {
        guard let registry = registry(),
              let data = try? Data(contentsOf: usageCacheFile),
              let entries = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        else { return [:] }
        var result: [String: CachedUsage] = [:]
        for (number, entry) in entries {
            guard let account = registry.accounts[number], let usage = entry.usage else { continue }
            result[account.organizationUuid.lowercased()] = usage
        }
        return result
    }

    /// 把缓存用量转成我们的 Snapshot。
    /// 默认 45 分钟算新鲜——ClaudeBar 自己的刷新节奏就在这个量级，
    /// 而 5h/7d 额度变化慢，45 分钟前的数字仍然可用。
    static func snapshot(org: String, maxAge: TimeInterval = 2700) -> Snapshot? {
        guard let cached = usageByOrg()[org.lowercased()] else { return nil }
        if let stamp = cached.fetchedAt, let date = parseISO(stamp) {
            let age = Date().timeIntervalSince(date)
            // 时间戳可能是未来值（对端写时间没考虑时区），未来超过一小时就当作不可信。
            if age > maxAge || age < -3600 { return nil }
        } else {
            return nil
        }
        return Snapshot(
            fiveHour: convert(cached.fiveHour),
            sevenDay: convert(cached.sevenDay),
            fetchedAt: parseISO(cached.fetchedAt)!,
            error: nil,
            source: "claudebar")
    }

    private static func convert(_ window: CachedUsage.Window?) -> UsageWindow? {
        guard let window else { return nil }
        var reset: Date?
        if let raw = window.resetsAt, !raw.hasPrefix("0001-") {
            reset = parseISO(raw)
        }
        return UsageWindow(utilization: window.utilizationPct, resetsAt: reset)
    }
}

// MARK: - Token 统计（读它的扫描缓存）

struct TokenQuarter {
    let date: Date
    let input: Int
    let output: Int
    let cacheCreate: Int
    let cacheRead: Int
    let requests: Int
    var total: Int { input + output + cacheCreate + cacheRead }
}

enum TokenScan {
    private struct ScanCache: Decodable {
        struct FileEntry: Decodable {
            let offset: Int?
            let quarters: [[Int]]?
        }
        let version: Int?
        let files: [String: FileEntry]
    }

    /// 读 ClaudeBar 的 15 分钟桶。每行格式：[quarter, input, output, cacheCreation, cacheRead, requests]，
    /// quarter 是 Unix 时间除以 900。这些数字已和阿月汇总逐项核对过。
    static func quarters() -> [TokenQuarter]? {
        guard let data = try? Data(contentsOf: ClaudeBarData.scanCacheFile),
              let cache = try? JSONDecoder().decode(ScanCache.self, from: data)
        else { return nil }
        var result: [TokenQuarter] = []
        for file in cache.files.values {
            guard let rows = file.quarters else { continue }
            for row in rows where row.count >= 6 {
                result.append(TokenQuarter(
                    date: Date(timeIntervalSince1970: Double(row[0]) * 900),
                    input: row[1], output: row[2],
                    cacheCreate: row[3], cacheRead: row[4],
                    requests: row[5]))
            }
        }
        return result.isEmpty ? nil : result
    }

    struct MonthlyTotal: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationTokens: Int?
        let cacheReadTokens: Int?
        let totalTokens: Int?
        let requests: Int?
    }

    static func monthlyHistory() -> [String: MonthlyTotal] {
        guard let data = try? Data(contentsOf: ClaudeBarData.monthlyFile),
              let result = try? JSONDecoder().decode([String: MonthlyTotal].self, from: data)
        else { return [:] }
        return result
    }
}

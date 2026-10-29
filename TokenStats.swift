// Token 用量统计。
//
// 数据源优先用 ClaudeBar 已经扫好的 usage/scan-cache.json（15 分钟桶），
// 它没在跑或者缓存缺了，才自己扫 ~/.claude/projects/**/*.jsonl。
// 自己扫的路径只读不写，切账号不会碰到这些文件。

import Foundation

struct TokenPoint: Identifiable {
    let date: Date
    let total: Int
    var id: Date { date }
}

struct TokenTotals {
    var today: Int = 0
    var week: Int = 0
    var month: Int = 0
    var all: Int = 0
    var requests: Int = 0
}

enum ChartGranularity: String, CaseIterable, Identifiable {
    case hour, day, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hour: return "24 小时"
        case .day: return "30 天"
        case .month: return "12 个月"
        }
    }
}

@MainActor
final class TokenStats: ObservableObject {
    static let shared = TokenStats()

    @Published private(set) var hourly: [TokenPoint] = []
    @Published private(set) var daily: [TokenPoint] = []
    @Published private(set) var monthly: [TokenPoint] = []
    @Published private(set) var heat: [TokenPoint] = []
    @Published private(set) var totals = TokenTotals()
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var source = "-"

    func reload() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let scan = Self.scanJSONL()
            let entries = scan.entries
            await MainActor.run {
                self.rebuild(entries: entries)
                self.source = "本地会话日志 · \(scan.files) 个文件 · \(scan.failures) 个读取失败"
                self.scanning = false
                self.lastScan = Date()
            }
        }
    }

    private func rebuild(entries: [TokenQuarter]) {
        let calendar = Calendar.current
        let now = Date()

        var byHour: [Date: Int] = [:]
        var byDay: [Date: Int] = [:]
        var byMonth: [Date: Int] = [:]
        var totalAll = 0
        var requests = 0

        for entry in entries {
            if let hour = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour],
                                                                     from: entry.date)) {
                byHour[hour, default: 0] += entry.total
            }
            let day = calendar.startOfDay(for: entry.date)
            byDay[day, default: 0] += entry.total
            if let month = calendar.date(from: calendar.dateComponents([.year, .month],
                                                                      from: entry.date)) {
                byMonth[month, default: 0] += entry.total
            }
            totalAll += entry.total
            requests += entry.requests
        }

        var hours: [TokenPoint] = []
        if let currentHour = calendar.date(from: calendar.dateComponents(
            [.year, .month, .day, .hour], from: now)) {
            for offset in stride(from: 23, through: 0, by: -1) {
                let slot = calendar.date(byAdding: .hour, value: -offset, to: currentHour) ?? now
                hours.append(TokenPoint(date: slot, total: byHour[slot] ?? 0))
            }
        }

        let today = calendar.startOfDay(for: now)
        var days: [TokenPoint] = []
        for offset in stride(from: 29, through: 0, by: -1) {
            let slot = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            days.append(TokenPoint(date: slot, total: byDay[slot] ?? 0))
        }

        var months: [TokenPoint] = []
        if let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) {
            for offset in stride(from: 11, through: 0, by: -1) {
                let slot = calendar.date(byAdding: .month, value: -offset, to: currentMonth) ?? now
                months.append(TokenPoint(date: slot, total: byMonth[slot] ?? 0))
            }
        }

        // 17 周热力图，按列排，最后一列落在本周。
        var heatPoints: [TokenPoint] = []
        let weekday = calendar.component(.weekday, from: today)
        let daysSinceFirst = (weekday - calendar.firstWeekday + 7) % 7
        let tail = (6 - daysSinceFirst) % 7
        let leading = 17 * 7 - tail - 1
        for offset in stride(from: leading, through: -tail, by: -1) {
            let slot = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            heatPoints.append(TokenPoint(date: slot, total: byDay[slot] ?? 0))
        }

        hourly = hours
        daily = days
        monthly = months
        heat = heatPoints

        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let week = byDay.filter { $0.key >= weekStart && $0.key <= today }.values.reduce(0, +)
        var month = 0
        for point in days { month += point.total }
        totals = TokenTotals(today: byDay[today] ?? 0,
                             week: week,
                             month: month,
                             all: totalAll,
                             requests: requests)
    }

    func series(for granularity: ChartGranularity) -> [TokenPoint] {
        switch granularity {
        case .hour: return hourly
        case .day: return daily
        case .month: return monthly
        }
    }

    // MARK: 兜底：自己扫 jsonl

    struct ScanResult { let entries: [TokenQuarter]; let files: Int; let failures: Int }
    private struct MessageUsage: Codable {
        var date: Date
        var input: Int
        var output: Int
        var cacheCreate: Int
        var cacheRead: Int
        mutating func merge(_ other: MessageUsage) {
            date = min(date, other.date)
            input = max(input, other.input); output = max(output, other.output)
            cacheCreate = max(cacheCreate, other.cacheCreate); cacheRead = max(cacheRead, other.cacheRead)
        }
    }
    private struct FileScan: Codable {
        var inode: UInt64
        var offset: UInt64 = 0
        var messages: [String: MessageUsage] = [:]
    }
    private struct ScanCache: Codable { var version = 1; var files: [String: FileScan] = [:] }

    nonisolated static func scanJSONL(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true),
        cacheURL: URL = Paths.configDir.appendingPathComponent("usage-scan-v1.json")) -> ScanResult {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var cache = (try? decoder.decode(ScanCache.self, from: Data(contentsOf: cacheURL))) ?? ScanCache()
        if cache.version != 1 { cache = ScanCache() }
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else {
            return ScanResult(entries: [], files: 0, failures: 1)
        }
        var paths: Set<String> = []
        var failures = 0
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let path = url.path
            paths.insert(path)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else {
                failures += 1; continue
            }
            var entry = cache.files[path] ?? FileScan(inode: inode)
            if entry.inode != inode || entry.offset > size { entry = FileScan(inode: inode) }
            if entry.offset < size {
                guard let handle = try? FileHandle(forReadingFrom: url) else { failures += 1; continue }
                do {
                    try handle.seek(toOffset: entry.offset)
                    var remaining = size - entry.offset
                    var pending = Data()
                    while remaining > 0 {
                        let chunk = try handle.read(upToCount: Int(min(remaining, 524288))) ?? Data()
                        if chunk.isEmpty { break }
                        remaining -= UInt64(chunk.count)
                        pending.append(chunk)
                        while let end = pending.firstIndex(of: 10) {
                            let count = pending.distance(from: pending.startIndex, to: end) + 1
                            let line = Data(pending.prefix(count - 1))
                            pending.removeFirst(count)
                            entry.offset += UInt64(count)
                            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                                  object["type"] as? String == "assistant",
                                  let message = object["message"] as? [String: Any],
                                  let usage = message["usage"] as? [String: Any],
                                  let stamp = object["timestamp"] as? String,
                                  let date = parseISO(stamp) else { continue }
                            let value = MessageUsage(date: date,
                                input: max(0, usage["input_tokens"] as? Int ?? 0),
                                output: max(0, usage["output_tokens"] as? Int ?? 0),
                                cacheCreate: max(0, usage["cache_creation_input_tokens"] as? Int ?? 0),
                                cacheRead: max(0, usage["cache_read_input_tokens"] as? Int ?? 0))
                            let key = sha256Hex(message["id"] as? String ?? "\(stamp)|\(value.input)|\(value.output)")
                            if entry.messages[key] != nil { entry.messages[key]?.merge(value) }
                            else { entry.messages[key] = value }
                        }
                        // 记录超长或损坏的行，避免单行无限占内存。下次不会把半行当有效记录。
                        if pending.count > 16 * 1024 * 1024 { throw FetchError(description: "会话行过长") }
                    }
                    try handle.close()
                } catch { try? handle.close(); failures += 1 }
            }
            cache.files[path] = entry
        }
        cache.files = cache.files.filter { paths.contains($0.key) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(cache) { try? privateWrite(data, to: cacheURL) }
        var messages: [String: MessageUsage] = [:]
        for file in cache.files.values {
            for (key, value) in file.messages {
                if messages[key] != nil { messages[key]?.merge(value) } else { messages[key] = value }
            }
        }
        var buckets: [Int: (input: Int, output: Int, cacheCreate: Int, cacheRead: Int, requests: Int)] = [:]
        for value in messages.values {
            let quarter = Int(value.date.timeIntervalSince1970 / 900)
            var bucket = buckets[quarter] ?? (0, 0, 0, 0, 0)
            bucket.input += value.input; bucket.output += value.output
            bucket.cacheCreate += value.cacheCreate; bucket.cacheRead += value.cacheRead
            bucket.requests += 1
            buckets[quarter] = bucket
        }
        return ScanResult(entries: buckets.map { key, value in
            TokenQuarter(date: Date(timeIntervalSince1970: Double(key) * 900),
                input: value.input, output: value.output, cacheCreate: value.cacheCreate,
                cacheRead: value.cacheRead, requests: value.requests)
        }, files: paths.count, failures: failures)
    }

}

func formatTokens(_ value: Int) -> String {
    if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
    return "\(value)"
}

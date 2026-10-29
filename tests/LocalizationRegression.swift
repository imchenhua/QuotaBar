import Foundation

@main struct LocalizationRegression {
    static func main() throws {
        let url = URL(fileURLWithPath: "Localization/en.json")
        let entries = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let catalog = TranslationCatalog(entries: entries)
        precondition(catalog.text("设置", language: .english) == "Settings")
        precondition(catalog.text("设置", language: .chinese) == "设置")
        precondition(catalog.text("设置", language: .system, preferred: ["en-US"]) == "Settings")
        precondition(catalog.text("设置", language: .system, preferred: ["zh-TW"]) == "设置")
        precondition(catalog.text("约12秒后可重试", language: .english) == "Try again in about 12s")
        precondition(catalog.text("已更新3个账号；2个暂需等待，约5分钟后可重试", language: .english) == "Updated 3 accounts; 2 accounts need to wait; try again in about 5m")
        precondition(catalog.text("最近 17 周 · 今日 1K · 本周 2K", language: .english) == "Last 17 weeks · Today 1K · Week 2K")
        precondition(catalog.text("已切到 当前，新启动的 Claude Code 会读取新凭据", language: .english).hasPrefix("Switched to 当前."), "Account nicknames in messages must remain unchanged")
        for identity in ["person@example.com", "Max 20x", "Pro Lite", "Claude · Work"] {
            precondition(catalog.text(identity, language: .english) == identity)
        }
        print("PASS: explicit/system languages, immediate translation, dynamic diagnostics, quota labels, unchanged account identities")
    }
}

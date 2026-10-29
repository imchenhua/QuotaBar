import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
    func code(preferred: [String] = Locale.preferredLanguages) -> String {
        if self != .system { return rawValue }
        return preferred.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system
    }
    var locale: Locale { Locale(identifier: code()) }
}

/// Translate only presentation strings. Cached quota data and account identities remain unchanged.
struct TranslationCatalog {
    let entries: [String: String]
    private let templates: [(NSRegularExpression, String, [String])]

    init(entries: [String: String]) {
        self.entries = entries
        templates = entries.keys.filter { $0.contains("{0}") }.sorted { $0.count > $1.count }.compactMap { key in
            let placeholders = (0..<8).map { "{\($0)}" }.filter { key.contains($0) }
            var pattern = NSRegularExpression.escapedPattern(for: key)
            for placeholder in placeholders {
                pattern = pattern.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: placeholder), with: "(.+?)")
            }
            guard let expression = try? NSRegularExpression(pattern: "^" + pattern + "$") else { return nil }
            return (expression, entries[key]!, placeholders)
        }
    }

    func text(_ source: String, language: AppLanguage = .current, preferred: [String] = Locale.preferredLanguages) -> String {
        guard language.code(preferred: preferred) == "en" else { return source }
        if let exact = entries[source] { return exact }
        if source.contains("；") {
            return source.components(separatedBy: "；").map { text($0, language: .english) }.joined(separator: "; ")
        }
        let range = NSRange(source.startIndex..., in: source)
        for (expression, target, placeholders) in templates {
            guard let match = expression.firstMatch(in: source, range: range) else { continue }
            var result = target
            for (index, placeholder) in placeholders.enumerated() {
                guard let capture = Range(match.range(at: index + 1), in: source) else { continue }
                let value = String(source[capture])
                let isDuration = value.range(of: #"^\d+(秒|分钟|小时|天|分)$"#, options: .regularExpression) != nil
                result = result.replacingOccurrences(of: placeholder, with: isDuration ? text(value, language: .english) : value)
            }
            return result
        }
        return source
    }

    static let bundled: TranslationCatalog = {
        let url = Bundle.main.url(forResource: "en", withExtension: "json", subdirectory: "Localization")
        let entries = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        return TranslationCatalog(entries: entries)
    }()
}

func L(_ source: String) -> String { TranslationCatalog.bundled.text(source) }

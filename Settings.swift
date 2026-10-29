// 用户设置。全部落在 UserDefaults，改一下立刻生效。

import Foundation
import SwiftUI

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case minimal, standard, detailed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .minimal: return "极简"
        case .standard: return "标准"
        case .detailed: return "详细"
        }
    }
    var hint: String {
        switch self {
        case .minimal: return "账号名和 7 天百分比"
        case .standard: return "账号名 · 5 小时 · 7 天"
        case .detailed: return "账号名及 5h / 7d 标签"
        }
    }
}

enum ChartStyle: String, CaseIterable, Identifiable {
    case wave, calendar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wave: return "曲线"
        case .calendar: return "热力图"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var language: AppLanguage {
        didSet { save(language.rawValue, "appLanguage") }
    }

    @Published var menuBarStyle: MenuBarStyle {
        didSet { save(menuBarStyle.rawValue, "menuBarStyle") }
    }
    @Published var showIcon: Bool {
        didSet { save(showIcon, "showIcon") }
    }
    /// 关掉后台轮询，只保留手动刷新。
    @Published var paused: Bool {
        didSet { save(paused, "paused") }
    }
    @Published var notifyEnabled: Bool {
        didSet { save(notifyEnabled, "notifyEnabled") }
    }
    @Published var notifyOnSwitch: Bool {
        didSet { save(notifyOnSwitch, "notifyOnSwitch") }
    }
    @Published var thresholdFive: Int {
        didSet { save(thresholdFive, "thresholdFive") }
    }
    @Published var thresholdSeven: Int {
        didSet { save(thresholdSeven, "thresholdSeven") }
    }
    @Published var autoRestartIDE: Bool {
        didSet { save(autoRestartIDE, "autoRestartIDE") }
    }
    @Published var keepAliveEnabled: Bool {
        didSet { save(keepAliveEnabled, "keepAliveEnabled") }
    }
    @Published var showTokenChart: Bool {
        didSet { save(showTokenChart, "showTokenChart") }
    }
    @Published var chartStyle: ChartStyle {
        didSet { save(chartStyle.rawValue, "chartStyle") }
    }
    @Published var chartGranularity: ChartGranularity {
        didSet { save(chartGranularity.rawValue, "chartGranularity") }
    }
    /// 电池供电或低电量模式下把轮询间隔拉长。
    @Published var adaptiveRefresh: Bool {
        didSet { save(adaptiveRefresh, "adaptiveRefresh") }
    }

    private init() {
        let d = UserDefaults.standard
        language = .current
        menuBarStyle = MenuBarStyle(rawValue: d.string(forKey: "menuBarStyle") ?? "") ?? .standard
        showIcon = d.object(forKey: "showIcon") as? Bool ?? true
        paused = d.bool(forKey: "paused")
        notifyEnabled = d.bool(forKey: "notifyEnabled")
        notifyOnSwitch = d.object(forKey: "notifyOnSwitch") as? Bool ?? true
        thresholdFive = d.object(forKey: "thresholdFive") as? Int ?? 85
        thresholdSeven = d.object(forKey: "thresholdSeven") as? Int ?? 90
        autoRestartIDE = d.bool(forKey: "autoRestartIDE")
        keepAliveEnabled = d.object(forKey: "keepAliveEnabled") as? Bool ?? true
        showTokenChart = d.object(forKey: "showTokenChart") as? Bool ?? true
        chartStyle = ChartStyle(rawValue: d.string(forKey: "chartStyle") ?? "") ?? .wave
        chartGranularity = ChartGranularity(rawValue: d.string(forKey: "chartGranularity") ?? "") ?? .day
        adaptiveRefresh = d.object(forKey: "adaptiveRefresh") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

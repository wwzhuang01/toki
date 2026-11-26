import AppKit
import Observation
import ServiceManagement
import SwiftUI
import TokiCore

enum Language: String, CaseIterable, Identifiable {
    case system, chinese, english
    var id: String { rawValue }
    var isChinese: Bool {
        switch self {
        case .system: Locale.preferredLanguages.first?.hasPrefix("zh") == true
        case .chinese: true
        case .english: false
        }
    }
    var locale: Locale { Locale(identifier: isChinese ? "zh-Hans-CN" : "en-US") }
    var title: String {
        switch self {
        case .system: isChinese ? "跟随系统" : "System"
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
}

enum MenuFormat: String, CaseIterable, Identifiable {
    case compact, prefix, cost
    var id: String { rawValue }
}

enum Currency: String, CaseIterable, Identifiable {
    case usd = "USD"
    case cny = "CNY"
    var id: String { rawValue }
}

@MainActor @Observable
final class AppState {
    var language: Language { didSet { save() } }
    var menuFormat: MenuFormat { didSet { save() } }
    var currency: Currency { didSet { save() } }
    var cnyRate: Double { didSet { save() } }
    var interval: Int { didSet { save(); scheduleChanged?() } }
    var enabled: Set<Provider> { didSet { save(); scheduleChanged?(); refreshRequested?() } }
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var loginError: String?
    var days = 1
    var summaries: [Int: UsageSummary] = [:]
    var refreshing = false
    var copied = false

    @ObservationIgnored var displayChanged: (() -> Void)?
    @ObservationIgnored var scheduleChanged: (() -> Void)?
    @ObservationIgnored var refreshRequested: (() -> Void)?
    private let defaults = UserDefaults.standard

    init() {
        language = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        menuFormat = MenuFormat(rawValue: defaults.string(forKey: "menuFormat") ?? "") ?? .compact
        currency = Currency(rawValue: defaults.string(forKey: "currency") ?? "") ?? .usd
        cnyRate = defaults.object(forKey: "cnyRate") as? Double ?? 7.25
        interval = defaults.object(forKey: "interval") as? Int ?? 60
        enabled = Set(defaults.stringArray(forKey: "providers")?.compactMap(Provider.init(rawValue:)) ?? Provider.allCases)
    }

    var summary: UsageSummary? { summaries[days] }
    var today: UsageSummary? { summaries[1] }
    var sourceStatuses: [SourceStatus] {
        today?.sources ?? Provider.allCases.map {
            SourceStatus(provider: $0, paths: [], state: enabled.contains($0) ? .missing : .disabled, files: 0)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval
                ? local("在系统设置的登录项中批准 Toki。", "Approve Toki in System Settings under Login Items.") : nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func local(_ chinese: String, _ english: String) -> String { language.isChinese ? chinese : english }

    func format(_ format: MenuFormat) -> String {
        switch format {
        case .compact: local("精简", "Compact")
        case .prefix: local("带前缀", "With Prefix")
        case .cost: local("带费用", "With Cost")
        }
    }

    func windowTitle(_ days: Int) -> String {
        switch days {
        case 1: local("今日", "Today")
        case 7: local("7 天", "7 Days")
        default: local("30 天", "30 Days")
        }
    }

    func sourceTitle(_ source: SourceState) -> String {
        switch source {
        case .ready: local("可用", "Available")
        case .missing: local("未检测到", "Not found")
        case .partial: local("部分可用", "Partial")
        case .disabled: local("已停用", "Disabled")
        }
    }

    func exact(_ value: Int64) -> String { value.formatted(.number.locale(language.locale)) }

    func compact(_ value: Int64) -> String {
        let divisor: Double
        let suffix: String
        switch value {
        case 1_000_000_000...: (divisor, suffix) = (1_000_000_000, "B")
        case 1_000_000...: (divisor, suffix) = (1_000_000, "M")
        case 1_000...: (divisor, suffix) = (1_000, "K")
        default: return String(value)
        }
        return (Double(value) / divisor).formatted(.number.precision(.fractionLength(0...2)).locale(language.locale)) + suffix
    }

    func compactInteger(_ value: Int64) -> String {
        let divisor: Double
        let suffix: String
        switch value {
        case 999_500_000_000...: (divisor, suffix) = (1_000_000_000_000, "T")
        case 999_500_000...: (divisor, suffix) = (1_000_000_000, "B")
        case 999_500...: (divisor, suffix) = (1_000_000, "M")
        case 1_000...: (divisor, suffix) = (1_000, "K")
        default: return String(value)
        }
        return Int64((Double(value) / divisor).rounded()).formatted(.number.locale(language.locale)) + suffix
    }

    func money(_ dollars: Double) -> String {
        let amount = currency == .usd ? dollars : dollars * cnyRate
        let prefix = currency == .usd ? "$" : "¥"
        return prefix + amount.formatted(.number.precision(.fractionLength(2)).locale(language.locale))
    }

    func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0...1)).locale(language.locale))
    }

    func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second().locale(language.locale))
    }

    func copySummary() {
        guard let summary else { return }
        var lines = ["Toki · \(windowTitle(days))",
                     "\(local("总 Token", "Total tokens")): \(exact(summary.totalTokens))",
                     "\(local("预估费用", "Estimated cost")): \(summary.usage.pricedRecords == 0 ? "—" : money(summary.usage.costUsd))",
                     "\(local("缓存节省", "Cache savings")): \(money(summary.usage.cacheSavingsUsd))"]
        for provider in summary.providers where provider.usage.totalTokens > 0 {
            lines.append("\(provider.provider.name): \(exact(provider.usage.totalTokens))")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.copied = false
        }
    }

    private func save() {
        defaults.set(language.rawValue, forKey: "language")
        defaults.set(menuFormat.rawValue, forKey: "menuFormat")
        defaults.set(currency.rawValue, forKey: "currency")
        defaults.set(cnyRate, forKey: "cnyRate")
        defaults.set(interval, forKey: "interval")
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: "providers")
        displayChanged?()
    }
}

extension Provider {
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.78, green: 0.35, blue: 0.18)
        case .codex: Color(red: 0.34, green: 0.36, blue: 0.78)
        case .antigravity: Color(red: 0.13, green: 0.54, blue: 0.70)
        case .opencode: Color(red: 0.23, green: 0.57, blue: 0.38)
        }
    }
}

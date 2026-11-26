import CoreFoundation
import Foundation

public enum Provider: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex, antigravity, opencode
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .opencode: "OpenCode"
        }
    }
}

public enum UsageSpeed: String, Codable, Sendable { case standard, fast, ultrafast }

public struct Tokens: Codable, Hashable, Sendable {
    public var uncachedInputTokens: Int64 = 0
    public var cachedInputTokens: Int64 = 0
    public var cacheCreationTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var reasoningTokens: Int64 = 0
    public var input: Int64 { uncachedInputTokens + cachedInputTokens + cacheCreationTokens }
    public var total: Int64 { input + outputTokens }

    static func + (left: Self, right: Self) -> Self {
        Self(
            uncachedInputTokens: left.uncachedInputTokens + right.uncachedInputTokens,
            cachedInputTokens: left.cachedInputTokens + right.cachedInputTokens,
            cacheCreationTokens: left.cacheCreationTokens + right.cacheCreationTokens,
            outputTokens: left.outputTokens + right.outputTokens,
            reasoningTokens: left.reasoningTokens + right.reasoningTokens
        )
    }

    func merging(_ other: Self) -> Self {
        Self(
            uncachedInputTokens: max(uncachedInputTokens, other.uncachedInputTokens),
            cachedInputTokens: max(cachedInputTokens, other.cachedInputTokens),
            cacheCreationTokens: max(cacheCreationTokens, other.cacheCreationTokens),
            outputTokens: max(outputTokens, other.outputTokens),
            reasoningTokens: max(reasoningTokens, other.reasoningTokens)
        )
    }
}

struct UsageRecord: Codable, Sendable {
    var provider: Provider
    var timestampMs: Int64
    var model: String
    var sessionId: String
    var totals: Tokens
    var cacheCreation1hTokens: Int64 = 0
    var reportedCostUsd: Double?
    var speed: UsageSpeed = .standard
    var dedupeKey: String?
    var rateModel: String?
    var unresolvedTurnId: String?

    mutating func merge(_ copy: Self) {
        totals = totals.merging(copy.totals)
        cacheCreation1hTokens = max(cacheCreation1hTokens, copy.cacheCreation1hTokens)
        if let cost = copy.reportedCostUsd { reportedCostUsd = max(reportedCostUsd ?? cost, cost) }
    }
}

typealias JSONObject = [String: Any]

func object(_ value: Any?) -> JSONObject { value as? JSONObject ?? [:] }
func json(_ bytes: Data) -> JSONObject? { (try? JSONSerialization.jsonObject(with: bytes)) as? JSONObject }
func text(_ value: Any?) -> String { value as? String ?? "" }
func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
func number(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue.isFinite else { return nil }
    return value.doubleValue
}
func count(_ value: Any?) -> Int64 {
    guard let value = number(value), value > 0 else { return 0 }
    return Int64(exactly: value.rounded(.down)) ?? 0
}
func replacing(_ value: String, _ pattern: String, _ replacement: String) -> String {
    value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
}
func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
}

struct TimestampParser {
    private let fractional: ISO8601DateFormatter
    private let whole = ISO8601DateFormatter()

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parse(_ value: Any?) -> Int64? {
        guard let value = value as? String else { return nil }
        guard let date = fractional.date(from: value) ?? whole.date(from: value) else { return nil }
        return date.milliseconds
    }
}

extension Date {
    var milliseconds: Int64 { Int64((timeIntervalSince1970 * 1_000).rounded()) }
    init(milliseconds: Int64) { self.init(timeIntervalSince1970: Double(milliseconds) / 1_000) }
}

struct UsageWindow {
    let days: Int
    let calendar: Calendar
    let start: Date
    let end: Date

    init(days: Int, now: Date, calendar: Calendar = .current) {
        self.days = days
        self.calendar = calendar
        let today = calendar.startOfDay(for: now)
        start = calendar.date(byAdding: .day, value: 1 - days, to: today) ?? today
        end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    func contains(_ milliseconds: Int64) -> Bool {
        (start.milliseconds..<end.milliseconds).contains(milliseconds)
    }

    var buckets: [Date] {
        if days == 1 {
            return Array(sequence(first: start) { previous in
                let next = previous.addingTimeInterval(3_600)
                return next < end ? next : nil
            })
        }
        return (0..<days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    func bucket(_ milliseconds: Int64) -> Date {
        let date = Date(milliseconds: milliseconds)
        return days == 1
            ? start.addingTimeInterval(floor(date.timeIntervalSince(start) / 3_600) * 3_600)
            : calendar.startOfDay(for: date)
    }
}

struct ModelSelector: Decodable {
    let model: String
    let provider: String?
    func matches(_ record: UsageRecord) -> Bool {
        model == trimmed(record.model) && (provider == nil || provider == record.provider.rawValue)
    }
}

struct ModelFilter: Decodable {
    var include: [ModelSelector]?
    var exclude: [ModelSelector]?
    func keeps(_ record: UsageRecord) -> Bool {
        (include?.contains { $0.matches(record) } ?? true) && !(exclude?.contains { $0.matches(record) } ?? false)
    }
}

struct UsageFile {
    let path: String
    var records: [UsageRecord]
}

public enum SourceState: String, Codable, Sendable {
    case ready, missing, partial, disabled
}

public struct SourceStatus: Codable, Sendable, Identifiable {
    public let provider: Provider
    public var paths: [String]
    public var state: SourceState
    public var files: Int
    public var malformedRecords: Int = 0
    public var id: Provider { provider }

    public init(provider: Provider, paths: [String], state: SourceState, files: Int, malformedRecords: Int = 0) {
        self.provider = provider
        self.paths = paths
        self.state = state
        self.files = files
        self.malformedRecords = malformedRecords
    }
}

public struct UsageBucket: Codable, Sendable {
    public var totals = Tokens()
    public var totalTokens: Int64 { totals.total }
    public var costUsd: Double = 0
    public var cacheSavingsUsd: Double = 0
    public var pricedRecords = 0
    public var unpricedRecords = 0
    public var sessions = 0
}

public struct ProviderSummary: Codable, Sendable, Identifiable {
    public let provider: Provider
    public let usage: UsageBucket
    public var id: Provider { provider }
}

public struct ModelSummary: Codable, Sendable, Identifiable {
    public let provider: Provider
    public let model: String
    public let usage: UsageBucket
    public var id: String { provider.rawValue + ":" + model }
}

public struct TrendPoint: Codable, Sendable, Identifiable {
    public let date: Date
    public let provider: Provider
    public let tokens: Int64
    public let costUsd: Double
    public let requests: Int
    public var id: String { "\(date.milliseconds):\(provider.rawValue)" }
}

public struct UsageSummary: Codable, Sendable {
    public let days: Int
    public let timeZone: String
    public let start: Date
    public let end: Date
    public let updatedAt: Date
    public let totalTokens: Int64
    public let usage: UsageBucket
    public let providers: [ProviderSummary]
    public let models: [ModelSummary]
    public let trend: [TrendPoint]
    public let sources: [SourceStatus]
    public let duplicatesDropped: Int
    public var partial: Bool { sources.contains { $0.state == .partial } }
}

enum Aggregation {
    private struct ModelKey: Hashable {
        let provider: Provider
        let model: String
    }

    private struct EventKey: Hashable {
        let session: String
        let timestamp: Int64
        let model: String
        let totals: Tokens
    }

    private enum DedupeKey: Hashable {
        case named(String)
        case moved(EventKey, Int)
    }

    private struct Accumulator {
        var bucket = UsageBucket()
        var sessions: Set<String> = []

        mutating func add(_ record: UsageRecord, price: Pricing.Result) {
            bucket.totals = bucket.totals + record.totals
            bucket.costUsd += price.cost ?? 0
            bucket.cacheSavingsUsd += price.savings
            if price.cost == nil { bucket.unpricedRecords += 1 } else { bucket.pricedRecords += 1 }
            if !record.sessionId.isEmpty { sessions.insert(record.provider.rawValue + ":" + record.sessionId) }
        }

        func finish() -> UsageBucket {
            var result = bucket
            result.sessions = sessions.count
            return result
        }
    }

    static func aliases(_ raw: [String: String]) -> [String: String] {
        var resolved: [String: String] = [:]
        for name in raw.keys {
            var visited: Set<String> = []
            var target = name
            while let next = raw[target], visited.insert(target).inserted { target = next }
            if raw[target] == nil { resolved[name] = target }
        }
        return resolved
    }

    static func dedupeWithinFile(_ records: [UsageRecord]) -> [UsageRecord] {
        var result: [UsageRecord] = []
        var indices: [String: Int] = [:]
        for record in records {
            if let key = record.dedupeKey {
                if let index = indices[key] {
                    result[index].merge(record)
                    continue
                }
                indices[key] = result.count
            }
            result.append(record)
        }
        return result
    }

    static func summarize(
        files: [UsageFile], window: UsageWindow, now: Date, pricing: Pricing = Pricing(),
        modelAliases: [String: String] = [:], filter: ModelFilter? = nil, sources: [SourceStatus] = []
    ) -> UsageSummary {
        var firstFile: [String: Int] = [:]
        var sharedSessions: Set<String> = []
        for (index, file) in files.enumerated() {
            for record in file.records where record.provider == .codex && !record.sessionId.isEmpty {
                if let first = firstFile[record.sessionId], first != index { sharedSessions.insert(record.sessionId) }
                else { firstFile[record.sessionId] = index }
            }
        }
        let resolved = aliases(modelAliases)
        var deduped: [UsageRecord] = []
        var seen: [DedupeKey: Int] = [:]
        var duplicates = 0
        for file in files {
            var occurrences: [EventKey: Int] = [:]
            for original in file.records {
                guard original.dedupeKey != nil || window.contains(original.timestampMs),
                      filter?.keeps(original) ?? true else { continue }
                var record = original
                let key: DedupeKey?
                if record.provider == .codex && sharedSessions.contains(record.sessionId) {
                    let event = EventKey(session: record.sessionId, timestamp: record.timestampMs,
                                         model: record.model, totals: record.totals)
                    occurrences[event, default: 0] += 1
                    key = .moved(event, occurrences[event, default: 0])
                } else {
                    key = record.dedupeKey.map(DedupeKey.named)
                }
                if let model = resolved[record.model] {
                    record = pricing.aliased(record, to: model)
                }
                if let key {
                    if let index = seen[key] {
                        if window.contains(deduped[index].timestampMs) { deduped[index].merge(record) }
                        duplicates += 1
                        continue
                    }
                    seen[key] = deduped.count
                }
                deduped.append(record)
            }
        }
        struct TrendTotals {
            var tokens: Int64 = 0
            var costUsd: Double = 0
            var requests: Int = 0
        }
        var total = Accumulator()
        var providers: [Provider: Accumulator] = [:]
        var models: [ModelKey: Accumulator] = [:]
        var trend: [Date: [Provider: TrendTotals]] = [:]
        for record in deduped where window.contains(record.timestampMs) {
            let price = pricing.price(record)
            total.add(record, price: price)
            providers[record.provider, default: Accumulator()].add(record, price: price)
            models[ModelKey(provider: record.provider, model: record.model), default: Accumulator()].add(record, price: price)
            var slot = trend[window.bucket(record.timestampMs), default: [:]][record.provider, default: TrendTotals()]
            slot.tokens += record.totals.total
            slot.costUsd += price.cost ?? 0
            slot.requests += 1
            trend[window.bucket(record.timestampMs), default: [:]][record.provider] = slot
        }
        return UsageSummary(
            days: window.days, timeZone: window.calendar.timeZone.identifier, start: window.start,
            end: window.end, updatedAt: now, totalTokens: total.bucket.totalTokens, usage: total.finish(),
            providers: Provider.allCases.map { ProviderSummary(provider: $0, usage: providers[$0]?.finish() ?? UsageBucket()) },
            models: models.map { ModelSummary(provider: $0.key.provider, model: $0.key.model, usage: $0.value.finish()) }
                .sorted { $0.usage.totalTokens == $1.usage.totalTokens ? $0.id < $1.id : $0.usage.totalTokens > $1.usage.totalTokens },
            trend: window.buckets.flatMap { date in
                Provider.allCases.map { provider in
                    let slot = trend[date]?[provider] ?? TrendTotals()
                    return TrendPoint(date: date, provider: provider, tokens: slot.tokens,
                                      costUsd: slot.costUsd, requests: slot.requests)
                }
            },
            sources: sources, duplicatesDropped: duplicates
        )
    }
}

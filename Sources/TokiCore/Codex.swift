import Foundation

struct CodexCounters: Codable, Equatable {
    var input: Int64
    var cached: Int64
    var write: Int64
    var output: Int64
    var reasoning: Int64
    var total: Int64

    private static var channels: [WritableKeyPath<Self, Int64>] { [
        \.input, \.cached, \.write, \.output, \.reasoning, \.total
    ] }

    static let zero = Self(input: 0, cached: 0, write: 0, output: 0, reasoning: 0, total: 0)

    init(input: Int64, cached: Int64, write: Int64, output: Int64, reasoning: Int64, total: Int64) {
        self.input = input
        self.cached = cached
        self.write = write
        self.output = output
        self.reasoning = reasoning
        self.total = total
    }

    init?(_ value: Any?) {
        guard let value = value as? JSONObject else { return nil }
        func integer(_ key: String, default fallback: Int64? = nil) -> Int64? {
            guard let raw = value[key] else { return fallback }
            guard let numeric = number(raw), abs(numeric) <= 9_007_199_254_740_991 else { return nil }
            return Int64(exactly: numeric)
        }
        guard let input = integer("input_tokens"), let output = integer("output_tokens"),
              let cached = integer("cached_input_tokens", default: 0),
              let write = integer("cache_write_input_tokens", default: 0),
              let reasoning = integer("reasoning_output_tokens", default: 0),
              let total = integer("total_tokens", default: input + output) else { return nil }
        self.init(input: input, cached: cached, write: write, output: output, reasoning: reasoning, total: total)
        guard valid else { return nil }
    }

    var empty: Bool { input + output == 0 }
    var valid: Bool {
        Self.channels.allSatisfy { self[keyPath: $0] >= 0 }
            && cached + write <= input && reasoning <= output && total >= input + output
    }

    func hasLowerChannel(than other: Self) -> Bool {
        Self.channels.contains { self[keyPath: $0] < other[keyPath: $0] }
    }

    func combining(_ other: Self, _ operation: (Int64, Int64) -> Int64) -> Self {
        var result = self
        for channel in Self.channels { result[keyPath: channel] = operation(self[keyPath: channel], other[keyPath: channel]) }
        return result
    }
}

struct CodexState: Codable {
    struct Request: Codable {
        var timestamp: Int64
        var model: String
        var turn: String
        var speed: UsageSpeed
        var sawSettings: Bool
        var usage: CodexCounters
    }

    struct SequenceStart: Codable, Equatable {
        let timestamp: Int64
        let usage: CodexCounters
    }

    var model = ""
    var speed: UsageSpeed = .standard
    var session = ""
    var last: CodexCounters?
    var cumulative: CodexCounters?
    var sequenceStart: SequenceStart?
    var cumulativeAt: Int64?
    var pending: [Request] = []
    var ledgerActive = false
    var malformed: [Int64] = []
    var sawMeta = false
    var modelProvider = ""
    var turn = ""
    var sawSettings = false
    var forkAnchor: Int64?

    mutating func parse(_ value: JSONObject, timestamps: TimestampParser) -> [UsageRecord] {
        guard let payload = value["payload"] as? JSONObject else { return [] }
        switch text(value["type"]) {
        case "session_meta":
            guard !sawMeta else { return [] }
            sawMeta = true
            session = text(payload["id"] ?? payload["session_id"])
            modelProvider = text(payload["model_provider"])
            let spawn = object(object(object(payload["source"])["subagent"])["thread_spawn"])
            if payload["forked_from_id"] is String || spawn["parent_thread_id"] is String {
                forkAnchor = timestamps.parse(value["timestamp"])
            }
            return []
        case "turn_context":
            ledgerActive = false
            if let model = payload["model"] as? String { self.model = model }
            turn = text(payload["model"]).isEmpty ? "" : text(payload["turn_id"])
            return []
        case "token_usage_record":
            guard let timestamp = timestamps.parse(value["timestamp"]),
                  let usage = CodexCounters(payload["usage"]), !model.isEmpty,
                  !forkCopy(timestamp) else { return [] }
            let request = attribution(timestamp, usage)
            let response = text(payload["response_id"])
            guard !response.isEmpty else {
                ledgerActive = false
                pending.append(request)
                return []
            }
            ledgerActive = true
            for entry in pending { advance(entry.usage) }
            advance(usage)
            dateBaseline(timestamp)
            var result = pending.map(record)
            pending.removeAll()
            var billed = record(request)
            let keyData = try? JSONEncoder().encode(["codex", session, response])
            billed.dedupeKey = keyData.map { String(decoding: $0, as: UTF8.self) }
            result.append(billed)
            return result
        default:
            break
        }

        switch text(payload["type"]) {
        case "thread_settings_applied":
            sawSettings = true
            if let settings = payload["thread_settings"] as? JSONObject {
                speed = Self.tier(text(settings["service_tier"]))
            }
            return []
        case "token_count":
            guard let info = payload["info"] as? JSONObject,
                  let timestamp = timestamps.parse(value["timestamp"]), !model.isEmpty else { return [] }
            return snapshot(info, timestamp: timestamp)
        default:
            return []
        }
    }

    private mutating func snapshot(_ info: JSONObject, timestamp: Int64) -> [UsageRecord] {
        let request = CodexCounters(info["last_token_usage"])
        let raw = info["total_token_usage"]
        let hasCumulative = raw != nil && !(raw is NSNull)
        let snapshot = CodexCounters(raw)
        if forkCopy(timestamp) {
            if let snapshot { rebase(snapshot, timestamp) }
            else if !hasCumulative, let request, request != last {
                advance(request)
                dateBaseline(timestamp)
            }
            last = request
            return []
        }
        if ledgerActive {
            if let snapshot { rebase(snapshot, timestamp) }
            return []
        }
        let previous = cumulative
        let previousDate = cumulativeAt
        let unreported = pending
        if let snapshot { rebase(snapshot, timestamp) }
        guard let request, !hasCumulative || snapshot != nil else {
            malformed.append(timestamp)
            return []
        }
        if request.empty {
            last = nil
            return []
        }
        if let snapshot, snapshot == previous { return [] }
        guard request.total == request.input + request.output else {
            malformed.append(timestamp)
            return []
        }
        var recovered: [Request] = []
        if let snapshot {
            let restarted = snapshot == request
            let start = SequenceStart(timestamp: timestamp, usage: request)
            if restarted && start == sequenceStart {
                cumulative = previous
                if previousDate == nil { cumulativeAt = nil }
                return []
            }
            let lowered = previous.map { snapshot.hasLowerChannel(than: $0) } ?? false
            let rewound = lowered && previousDate.map { timestamp > $0 } == true
            let reconciled = previous == nil || rewound
                ? snapshot.combining(request, -).valid
                : snapshot.combining(previous ?? .zero, -) == request
            if !restarted && !reconciled {
                guard let bridge = bridge(previous, snapshot, request, unreported) else {
                    if let previousDate,
                       timestamp < previousDate || (timestamp == previousDate && lowered && !snapshot.empty) {
                        cumulative = previous
                        pending = unreported
                    }
                    malformed.append(timestamp)
                    return []
                }
                recovered = bridge
            } else if !restarted && rewound {
                let discarded = unreported.count - (unreported.last?.usage == request ? 1 : 0)
                malformed.append(contentsOf: repeatElement(timestamp, count: discarded))
            }
            if restarted { sequenceStart = start }
        } else {
            if request == last { return [] }
            guard advance(request) else {
                malformed.append(timestamp)
                return []
            }
            dateBaseline(timestamp)
        }
        last = request
        return recovered.map(record) + [record(attribution(timestamp, request))]
    }

    private func bridge(_ previous: CodexCounters?, _ snapshot: CodexCounters,
                        _ last: CodexCounters, _ pending: [Request]) -> [Request]? {
        guard let previous, var final = pending.last,
              snapshot.combining(previous, -) == pending.reduce(.zero, { $0.combining($1.usage, +) }) else { return nil }
        final.usage = final.usage.combining(last, -)
        guard final.usage.valid else { return nil }
        return (Array(pending.dropLast()) + [final]).filter { !$0.usage.empty }
    }

    private mutating func forkCopy(_ timestamp: Int64) -> Bool {
        guard let anchor = forkAnchor else { return false }
        if timestamp - anchor < 1_000 {
            forkAnchor = timestamp
            return true
        }
        forkAnchor = nil
        last = nil
        return false
    }

    private mutating func rebase(_ counters: CodexCounters, _ timestamp: Int64) {
        cumulative = counters
        dateBaseline(timestamp)
        pending.removeAll()
        if counters.empty { sequenceStart = nil }
    }

    private mutating func dateBaseline(_ timestamp: Int64) {
        cumulativeAt = max(cumulativeAt ?? timestamp, timestamp)
    }

    @discardableResult
    private mutating func advance(_ counters: CodexCounters) -> Bool {
        let next = (cumulative ?? .zero).combining(counters, +)
        if next.valid { cumulative = next }
        return next.valid
    }

    private func attribution(_ timestamp: Int64, _ usage: CodexCounters) -> Request {
        Request(timestamp: timestamp, model: model, turn: turn, speed: speed, sawSettings: sawSettings, usage: usage)
    }

    private func record(_ request: Request) -> UsageRecord {
        let usage = request.usage
        return UsageRecord(
            provider: .codex, timestampMs: request.timestamp, model: request.model, sessionId: session,
            totals: Tokens(uncachedInputTokens: usage.input - usage.cached - usage.write,
                           cachedInputTokens: usage.cached, cacheCreationTokens: usage.write,
                           outputTokens: usage.output, reasoningTokens: usage.reasoning),
            speed: request.speed,
            unresolvedTurnId: !request.sawSettings && modelProvider == "openai" && !session.isEmpty
                && !request.turn.isEmpty ? request.turn : nil
        )
    }

    static func tier(_ value: String) -> UsageSpeed {
        switch value {
        case "priority", "fast": .fast
        case "ultrafast": .ultrafast
        default: .standard
        }
    }
}
